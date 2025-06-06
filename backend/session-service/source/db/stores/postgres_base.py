# data_access/stores/postgres/postgres_base.py
"""
Base PostgreSQL connection management and generic repository implementation.
"""
import logging
import asyncio
import asyncpg
import datetime
from typing import Optional, Dict, Any, TypeVar, Generic, Type

from opentelemetry import trace

from source.config import config
from source.utils.tracing import optional_trace_span
from source.utils.metrics import track_db_error

from source.models.exchange_data import ExchangeType

logger = logging.getLogger(__name__)

T = TypeVar('T')


class PostgresBase:
    """Base PostgreSQL connection handler"""

    def __init__(self, db_config=None):
        """Initialize PostgreSQL base connection"""
        self.pool: Optional[asyncpg.Pool] = None
        self.db_config = db_config or config.db
        self._conn_lock = asyncio.Lock()
        self.tracer = trace.get_tracer("postgres_base")

    async def connect(self):
        """Connect to the PostgreSQL database"""
        with optional_trace_span(self.tracer, "pg_connect") as span:
            span.set_attribute("db.system", "postgresql")
            span.set_attribute("db.name", self.db_config.database)
            span.set_attribute("db.host", self.db_config.host)

            async with self._conn_lock:
                if self.pool is not None:
                    return

                max_retries = self.db_config.max_retries
                retry_count = 0
                retry_delay = self.db_config.retry_delay

                while retry_count < max_retries:
                    try:
                        self.pool = await asyncpg.create_pool(
                            host=self.db_config.host,
                            port=self.db_config.port,
                            user=self.db_config.user,
                            password=self.db_config.password,
                            database=self.db_config.database,
                            min_size=self.db_config.min_connections,
                            max_size=self.db_config.max_connections
                        )

                        logger.info("Successfully connected to PostgreSQL database")
                        span.set_attribute("success", True)
                        return

                    except Exception as e:
                        retry_count += 1
                        logger.error(f"PostgreSQL connection error (attempt {retry_count}/{max_retries}): {e}")
                        span.record_exception(e)
                        span.set_attribute("retry_count", retry_count)

                        if retry_count < max_retries:
                            await asyncio.sleep(retry_delay)
                            retry_delay *= 2  # Exponential backoff
                        else:
                            logger.error("Maximum PostgreSQL connection retries reached")
                            span.set_attribute("success", False)
                            track_db_error("pg_connect")
                            raise ConnectionError("Failed to connect to PostgreSQL after multiple retries.") from e

    async def close(self):
        """Close PostgreSQL database connections"""
        async with self._conn_lock:
            if self.pool:
                logger.info("Closing PostgreSQL database connection pool...")
                await self.pool.close()
                self.pool = None
                logger.info("Closed PostgreSQL database connection pool.")
            else:
                logger.info("PostgreSQL connection pool already closed.")

    async def check_connection(self) -> bool:
        """Check PostgreSQL database connection health"""
        if not self.pool:
            logger.warning("Checking connection status: Pool does not exist.")
            return False

        try:
            async with self.pool.acquire() as conn:
                result = await asyncio.wait_for(conn.fetchval("SELECT 1"), timeout=5.0)
                is_healthy = (result == 1)
                logger.debug(f"PostgreSQL connection check result: {is_healthy}")
                return is_healthy
        except asyncpg.exceptions.ProtocolViolationError as e:
            # pgbouncer error - need to recreate the pool
            logger.error(f"PostgreSQL connection pool error (pgbouncer): {e}")

            # Try to close the existing pool
            try:
                if self.pool:
                    await self.pool.close()
            except Exception as close_error:
                logger.error(f"Error closing pool: {close_error}")

            # Set pool to None and trigger reconnect on next operation
            self.pool = None
            return False
        except (asyncio.TimeoutError, Exception) as e:
            logger.error(f"PostgreSQL connection check failed: {e}", exc_info=True)
            return False

    async def _get_pool(self) -> asyncpg.Pool:
        """Internal helper to get the pool, ensuring it's connected"""
        if self.pool is None:
            logger.warning("Accessing pool before explicit connect(). Attempting connection...")
            await self.connect()
        if self.pool is None:
            raise ConnectionError("PostgreSQL pool is not initialized.")
        return self.pool


class PostgresRepository(PostgresBase, Generic[T]):
    """Generic PostgreSQL repository with improved CRUD operations"""

    def __init__(self,
                 entity_class: Type[T],
                 schema_name: str,
                 table_name: str,
                 id_field: str = None,
                 tracer_name: str = None,
                 db_config=None):
        """Initialize a generic repository"""
        super().__init__(db_config)
        self.entity_class = entity_class
        self.schema_name = schema_name
        self.table_name = table_name
        self.id_field = id_field or f"{self.table_name[:-1]}_id"  # Default: singular + _id
        self.full_table_name = f"{schema_name}.{table_name}"
        self.tracer = trace.get_tracer(tracer_name or f"postgres_{table_name}_store")
        logger.info(f"Initialized repository for {self.full_table_name} with entity {entity_class.__name__}")

    # Helper methods

    def _row_to_entity(self, row: asyncpg.Record) -> Optional[T]:
        """
        Convert database row to entity object.
        Subclasses should override this to handle specific entity conversion.

        Args:
            row: Database row from query

        Returns:
            Entity object or None on error
        """
        try:
            # Convert row to dictionary
            row_dict = dict(row)

            for key in row_dict.keys():
                if isinstance(row_dict[key], datetime.datetime):
                    row_dict[key] = row_dict[key].timestamp()

            # Convert exchange_type string to enum
            if 'exchange_type' in row_dict:
                try:
                    row_dict['exchange_type'] = ExchangeType(row_dict['exchange_type'])
                except ValueError:
                    row_dict['exchange_type'] = ExchangeType.EQUITIES  # Default

            # Create entity object
            return self.entity_class(**row_dict)
        except Exception as e:
            logger.error(f"Error converting row to {self.entity_class.__name__}: {e}")
            return None

    def _entity_to_dict(self, entity: T) -> Dict[str, Any]:
        """
        Convert entity to dictionary for database operations

        Args:
            entity: The entity object

        Returns:
            Dictionary of field/value pairs
        """
        try:
            # Use the entity's .dict() method if available (for Pydantic models)
            if hasattr(entity, 'dict'):
                return entity.dict()
            # Otherwise use the entity's __dict__ attribute
            return entity.__dict__
        except Exception as e:
            logger.error(f"Error converting {self.entity_class.__name__} to dict: {e}")
            return {}
