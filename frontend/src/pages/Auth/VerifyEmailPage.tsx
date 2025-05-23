// src/pages/Auth/VerifyEmailPage.tsx
import React, { useState, useEffect } from 'react';
import { useLocation, useNavigate, useSearchParams } from 'react-router-dom';
import AuthLayout from './AuthLayout';
import { useToast } from '../../hooks/useToast';
import './AuthForms.css';

// Import API client
import { authApi } from '../../api';

interface LocationState {
  userId?: string | number;
  email?: string;
  needsVerification?: boolean;
}

const VerifyEmailPage: React.FC = () => {
  const [verificationCode, setVerificationCode] = useState('');
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [isResending, setIsResending] = useState(false);
  const [resendCooldown, setResendCooldown] = useState(0);
  
  // Add search params to support query string parameters
  const location = useLocation();
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const { addToast } = useToast();
  
  // Extract state passed from signup/login AND check URL query params as fallback
  const locationState = location.state as LocationState;
  const userId = locationState?.userId || searchParams.get('userId') || '';
  const email = locationState?.email || searchParams.get('email') || '';
  const needsVerification = locationState?.needsVerification || searchParams.get('needsVerification') === 'true';
  
  useEffect(() => {
    // Redirect if no userId found - with more detailed error
    if (!userId) {
      console.error("Missing verification info:", { 
        hasState: !!location.state,
        locationUserId: locationState?.userId,
        locationEmail: locationState?.email,
        queryUserId: searchParams.get('userId'),
        queryEmail: searchParams.get('email')
      });
      
      addToast('error', 'Missing information required for verification. Please try signing up again.');
      navigate('/signup', { replace: true });
    }
  }, [userId, email, addToast, navigate, location.state, searchParams]);
  
  // Handle resend cooldown timer
  useEffect(() => {
    let timerId: number;
    if (resendCooldown > 0) {
      timerId = window.setTimeout(() => {
        setResendCooldown(prev => prev - 1);
      }, 1000);
    }
    return () => {
      if (timerId) clearTimeout(timerId);
    };
  }, [resendCooldown]);

  const handleCodeChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    // Only allow numbers
    const value = e.target.value.replace(/\D/g, '');
    setVerificationCode(value);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    
    if (!verificationCode.trim()) {
      addToast('warning', 'Please enter the verification code');
      return;
    }
    
    setIsSubmitting(true);
    
    try {
      const response = await authApi.verifyEmail({
        userId: userId,
        code: verificationCode
      });
      
      if (response.success) {
        addToast('success', 'Email verified successfully!');
        navigate('/login', { 
          state: { verified: true } 
        });
      } else {
        addToast('error', response.error || 'Invalid verification code');
      }
    } catch (error: any) {
      addToast('error', error.message || 'Error verifying email');
    } finally {
      setIsSubmitting(false);
    }
  };

  const handleResendCode = async () => {
    if (resendCooldown > 0) return;
    
    setIsResending(true);
    
    try {
      const response = await authApi.resendVerification({
        userId: userId
      });
      
      if (response.success) {
        addToast('success', 'A new verification code has been sent to your email');
        setResendCooldown(60); // 60 seconds cooldown
      } else {
        addToast('error', response.error || 'Failed to resend verification code');
      }
    } catch (error: any) {
      addToast('error', error.message || 'Error requesting new code');
    } finally {
      setIsResending(false);
    }
  };

  return (
    <AuthLayout 
      title="Verify Your Email" 
      subtitle={email ? 
        `We've sent a verification code to ${email}. Please check your inbox.` : 
        "We've sent a verification code to your email. Please check your inbox."
      }
    >
      <form className="auth-form" onSubmit={handleSubmit}>
        <div className="form-group verification-code-group">
          <label htmlFor="verificationCode">Verification Code</label>
          <input
            id="verificationCode"
            type="text"
            value={verificationCode}
            onChange={handleCodeChange}
            disabled={isSubmitting}
            placeholder="Enter 6-digit code"
            maxLength={6}
            autoFocus
          />
        </div>
        
        <button 
          type="submit" 
          className="auth-button" 
          disabled={isSubmitting || verificationCode.length !== 6}
        >
          {isSubmitting ? 'Verifying...' : 'Verify Email'}
        </button>
        
        <div className="auth-links">
          <button 
            type="button" 
            className="text-button"
            onClick={handleResendCode}
            disabled={isResending || resendCooldown > 0}
          >
            {resendCooldown > 0 
              ? `Resend code in ${resendCooldown}s` 
              : isResending 
                ? 'Resending...' 
                : "Didn't receive a code? Resend"
            }
          </button>
        </div>
      </form>
    </AuthLayout>
  );
};

export default VerifyEmailPage;