/**
 * src/hooks/useContinuousMode.ts
 * 
 * WCAG 2.1 Level AA Compliant Continuous Mode Hook
 * 
 * UPDATED: Feb 6, 2026 - Priority for reaching_ios over reaching_flag
 * 
 * This hook handles the continuous mode loop for navigation and reaching,
 * with special handling for iOS ARKit reaching which takes priority.
 * 
 * PRIORITY ORDER:
 * 1. reaching_ios=true → Trigger iOS ARKit (no loop, native takeover)
 * 2. reaching_flag=true → Start reaching continuous loop
 * 3. navigation=true → Start navigation continuous loop
 */

import { useCallback, useRef, useState, useEffect } from 'react';
import { Platform, NativeModules, AccessibilityInfo } from 'react-native';
import {
    sendToWorkflow,
    startContinuousMode as startMode,
    stopContinuousMode as stopMode,
    incrementContinuousMode,
    updateLoopDelay,
    shouldPreventInfiniteLoop,
    isContinuousModeActive,
    getCurrentMode,
    determineActionMode,
    triggerIOSReaching,
    ActionMode,
} from '../services/WorkflowService';
import { WorkflowResponse } from '../utils/types';
import { AccessibilityService } from '../services/AccessibilityService';

interface UseContinuousModeProps {
    capturePhoto: () => Promise<string | null>;
    speakText: (text: string) => Promise<void>;
    playEarcon: (type: 'thinking' | 'speaking' | 'ready' | 'error' | 'cancel') => void;
    onStop?: (reason: string) => void;
    onIOSReachingTriggered?: (object: string) => void;
}

interface UseContinuousModeReturn {
    isActive: boolean;
    currentMode: 'navigation' | 'reaching' | 'reaching_ios' | null;
    iterationCount: number;
    handleBackendResponse: (response: WorkflowResponse) => Promise<void>;
    startLoop: (mode: 'navigation' | 'reaching', loopDelay?: number) => void;
    stopLoop: (reason: string) => void;
}

export const useContinuousMode = ({
    capturePhoto,
    speakText,
    playEarcon,
    onStop,
    onIOSReachingTriggered,
}: UseContinuousModeProps): UseContinuousModeReturn => {
    const [isActive, setIsActive] = useState(false);
    const [currentMode, setCurrentMode] = useState<'navigation' | 'reaching' | 'reaching_ios' | null>(null);
    const [iterationCount, setIterationCount] = useState(0);

    const isRunningRef = useRef(false);
    const abortControllerRef = useRef<AbortController | null>(null);

    // =========================================================================
    // Stop the continuous loop
    // =========================================================================
    const stopLoop = useCallback((reason: string) => {
        console.log(`🛑 Stopping continuous mode: ${reason}`);

        isRunningRef.current = false;

        // Abort any pending requests
        if (abortControllerRef.current) {
            abortControllerRef.current.abort();
            abortControllerRef.current = null;
        }

        stopMode(reason);
        setIsActive(false);
        setCurrentMode(null);
        setIterationCount(0);

        playEarcon('cancel');
        onStop?.(reason);
    }, [playEarcon, onStop]);

    // =========================================================================
    // Handle iOS ARKit Reaching (PRIORITY 1)
    // =========================================================================
    const handleIOSReaching = useCallback(async (
        bbox: [number, number, number, number],
        objectName: string
    ): Promise<boolean> => {
        if (Platform.OS !== 'ios') {
            console.warn('🚫 iOS reaching called on non-iOS platform');
            return false;
        }

        console.log('🎯 [iOS ARKit] Starting reaching for:', objectName);
        console.log('📦 [iOS ARKit] Bounding box:', bbox);

        // Stop any existing continuous mode
        if (isRunningRef.current) {
            stopLoop('iOS ARKit takeover');
        }

        setCurrentMode('reaching_ios');

        // Announce to user
        AccessibilityService.announceForAccessibility(
            `Guiding you to ${objectName}. Follow the audio cues.`
        );

        // Trigger the native iOS module
        const success = await triggerIOSReaching(bbox, objectName);

        if (success) {
            onIOSReachingTriggered?.(objectName);
        } else {
            // If native module not available, fall back to reaching loop
            console.warn('⚠️ iOS ARKit not available, falling back to reaching loop');
            setCurrentMode(null);
            return false;
        }

        return success;
    }, [stopLoop, onIOSReachingTriggered]);

    // =========================================================================
    // Start the continuous loop
    // =========================================================================
    const startLoop = useCallback((mode: 'navigation' | 'reaching', loopDelay?: number) => {
        if (isRunningRef.current) {
            console.log('⚠️ Continuous mode already running, stopping first');
            stopLoop('resetting for new loop');
        }

        console.log(`🔄 [${mode}] Starting continuous mode`);

        isRunningRef.current = true;
        setIsActive(true);
        setCurrentMode(mode);
        setIterationCount(0);

        startMode(mode, loopDelay);

        // Run the loop
        runLoop(mode, loopDelay);
    }, [stopLoop]);

    // =========================================================================
    // Main loop execution
    // =========================================================================
    const runLoop = useCallback(async (mode: 'navigation' | 'reaching', loopDelay?: number) => {
        const delay = loopDelay || 2500;

        console.log('🔄 Starting fresh continuous loop...');
        console.log(`🔄 [ContinuousMode] Starting loop`);

        while (isRunningRef.current) {
            try {
                incrementContinuousMode();
                setIterationCount(prev => prev + 1);

                // Wait before next iteration
                console.log(`🔄 [ContinuousMode] Waiting ${delay}ms before next iteration`);
                await new Promise(resolve => setTimeout(resolve, delay));

                if (!isRunningRef.current) {
                    console.log('🔄 [ContinuousMode] Cancelled during delay');
                    break;
                }

                // Check rate limiting
                if (shouldPreventInfiniteLoop()) {
                    console.warn('⚠️ Rate limit reached, stopping loop');
                    stopLoop('rate limit');
                    break;
                }

                // Capture photo
                console.log('🔄 [ContinuousMode] Capturing photo...');
                const photoPath = await capturePhoto();

                if (!photoPath) {
                    console.error('❌ Failed to capture photo, stopping loop');
                    stopLoop('photo capture failed');
                    break;
                }

                if (!isRunningRef.current) {
                    console.log('🔄 [ContinuousMode] Cancelled during capture');
                    break;
                }

                // Create abort controller for this request
                abortControllerRef.current = new AbortController();

                // Send to backend
                console.log('🔄 [ContinuousMode] Sending to backend...');
                const response = await sendToWorkflow(
                    {
                        text: '(continuous mode)',
                        imageUri: photoPath,
                        navigation: mode === 'navigation',
                        reaching_flag: mode === 'reaching',
                    },
                    abortControllerRef.current.signal
                );

                if (!isRunningRef.current) {
                    console.log('🔄 [ContinuousMode] Cancelled during request');
                    break;
                }

                console.log('🔄 [ContinuousMode] Backend response:', {
                    text: response.text.substring(0, 50),
                    navigation: response.navigation,
                    reaching_flag: response.reaching_flag,
                    reaching_ios: response.reaching_ios,  
                    bbox: response.bbox,                   
                    object: response.object,             
                    loopDelay: response.loopDelay
                });

                // =====================================================================
                // ★★★ PRIORITY HANDLING ★★★
                // =====================================================================

                const action = determineActionMode(response);

                console.log('🔄 [ContinuousMode] Action:', action.type);

                // PRIORITY 1: iOS ARKit takes over
                if (action.type === 'reaching_ios') {
                    console.log('🎯 [ContinuousMode] iOS ARKit detected, handing over...');

                    // Speak the response first
                    if (response.text) {
                        await speakText(response.text);
                    }

                    // Then trigger iOS ARKit
                    await handleIOSReaching(action.bbox, action.object);

                    // Stop this loop - native iOS takes over
                    isRunningRef.current = false;
                    setIsActive(false);
                    setCurrentMode('reaching_ios');
                    break;
                }

                // Check if backend wants to stop
                const bothInactive = !response.navigation && !response.reaching_flag;
                console.log('🔄 [ContinuousMode] Flag status:', {
                    navigation: response.navigation,
                    reaching: response.reaching_flag,
                    bothInactive,
                });

                if (bothInactive) {
                    console.log('🔄 [ContinuousMode] Backend signaled stop');

                    // Speak final response
                    if (response.text) {
                        await speakText(response.text);
                    }

                    stopLoop('backend stopped');
                    break;
                }

                // Update delay if provided
                if (response.loopDelay && response.loopDelay > 0) {
                    updateLoopDelay(response.loopDelay);
                }

                // Speak the response
                console.log('🔄 [ContinuousMode] Speaking response...');
                if (response.text) {
                    await speakText(response.text);
                }

                if (!isRunningRef.current) {
                    console.log('🔄 [ContinuousMode] Cancelled during playback');
                    break;
                }

            } catch (error: any) {
                if (error.message?.includes('cancel')) {
                    console.log('🔄 [ContinuousMode] Request cancelled');
                    break;
                }

                console.error('❌ [ContinuousMode] Loop error:', error);
                stopLoop('error');
                break;
            }
        }

        console.log('🔄 [ContinuousMode] Loop ended');
    }, [capturePhoto, speakText, stopLoop, handleIOSReaching]);

    // =========================================================================
    // Handle initial backend response (decides what mode to start)
    // =========================================================================
    const handleBackendResponse = useCallback(async (response: WorkflowResponse) => {
        console.log('🔄 Handling backend response...');

        const action = determineActionMode(response);

        switch (action.type) {
            case 'reaching_ios':
                console.log('🎯 Backend requested iOS ARKit reaching');
                await handleIOSReaching(action.bbox, action.object);
                break;

            case 'reaching':
                console.log('🔄 Backend requested reaching loop');
                startLoop('reaching', action.loopDelay);
                break;

            case 'navigation':
                console.log('🗺️ Backend requested navigation loop');
                startLoop('navigation', action.loopDelay);
                break;

            case 'none':
                console.log('✅ No continuous mode needed');
                break;
        }
    }, [handleIOSReaching, startLoop]);

    // =========================================================================
    // Cleanup on unmount
    // =========================================================================
    useEffect(() => {
        return () => {
            if (isRunningRef.current) {
                stopLoop('component unmount');
            }
        };
    }, [stopLoop]);

    return {
        isActive,
        currentMode,
        iterationCount,
        handleBackendResponse,
        startLoop,
        stopLoop,
    };
};

export default useContinuousMode;