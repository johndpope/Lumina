//
//  SessionConfigurationExtension.swift
//  Lumina
//
//  Created by David Okun on 11/20/17.
//  Copyright © 2017 David Okun. All rights reserved.
//

import Foundation
import AVFoundation

extension LuminaCamera {
    func requestVideoPermissions() {
        self.sessionQueue.suspend()
        AVCaptureDevice.requestAccess(for: .video) { success in
            if success {
                self.sessionQueue.resume()
                self.delegate?.cameraSetupCompleted(camera: self, result: .requiresUpdate)
            } else {
                self.delegate?.cameraSetupCompleted(camera: self, result: .videoPermissionDenied)
            }
        }
    }

    func requestAudioPermissions() {
        self.sessionQueue.suspend()
        AVCaptureDevice.requestAccess(for: AVMediaType.audio) { success in
            if success {
                self.sessionQueue.resume()
                self.delegate?.cameraSetupCompleted(camera: self, result: .requiresUpdate)
            } else {
                self.delegate?.cameraSetupCompleted(camera: self, result: .audioPermissionDenied)
            }
        }
    }

    func updateOutputVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        self.videoBufferQueue.async {
            for output in self.session.outputs {
                guard let connection = output.connection(with: AVMediaType.video) else {
                    continue
                }
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = orientation
                }
            }
        }
    }

    func restartVideo() {
        if self.session.isRunning {
            self.session.stopRunning()
            updateVideo({ result in
                if result == .videoSuccess {
                    self.start()
                } else {
                    self.delegate?.cameraSetupCompleted(camera: self, result: result)
                }
            })
        }
    }

    func updateAudio(_ completion: @escaping (_ result: CameraSetupResult) -> Void) {
        self.sessionQueue.async {
            self.purgeAudioDevices()
            switch AVCaptureDevice.authorizationStatus(for: AVMediaType.audio) {
            case .authorized:
                guard let audioInput = self.getNewAudioInputDevice() else {
                    completion(CameraSetupResult.invalidAudioInput)
                    return
                }
                guard self.session.canAddInput(audioInput) else {
                    completion(CameraSetupResult.invalidAudioInput)
                    return
                }
                self.audioInput = audioInput
                self.session.addInput(audioInput)
                completion(CameraSetupResult.audioSuccess)
                return
            case .denied:
                completion(CameraSetupResult.audioPermissionDenied)
                return
            case .notDetermined:
                completion(CameraSetupResult.audioRequiresAuthorization)
                return
            case .restricted:
                completion(CameraSetupResult.audioPermissionRestricted)
                return
            }
        }
    }

    func updateVideo(_ completion: @escaping (_ result: CameraSetupResult) -> Void) {
        self.sessionQueue.async {
            self.purgeVideoDevices()
            switch AVCaptureDevice.authorizationStatus(for: AVMediaType.video) {
            case .authorized:
                completion(self.videoSetupApproved())
            case .denied:
                completion(CameraSetupResult.videoPermissionDenied)
                return
            case .notDetermined:
                completion(CameraSetupResult.videoRequiresAuthorization)
                return
            case .restricted:
                completion(CameraSetupResult.videoPermissionRestricted)
                return
            }
        }
    }

    private func videoSetupApproved() -> CameraSetupResult {
        self.torchState = false
        self.session.sessionPreset = .high // set to high here so that device input can be added to session. resolution can be checked for update later
        guard let videoInput = self.getNewVideoInputDevice() else {
            return .invalidVideoInput
        }
        if let failureResult = checkSessionValidity(for: videoInput) {
            return failureResult
        }
        self.videoInput = videoInput
        self.session.addInput(videoInput)
        if self.streamFrames {
            self.session.addOutput(self.videoDataOutput)
        }
        self.session.addOutput(self.photoOutput)
        self.session.commitConfiguration()
        if self.session.canSetSessionPreset(self.resolution.foundationPreset()) {
            self.session.sessionPreset = self.resolution.foundationPreset()
        }
        configureVideoRecordingOutput(for: self.session)
        configureMetadataOutput(for: self.session)
        configureHiResPhotoOutput(for: self.session)
        configureLivePhotoOutput(for: self.session)
        configureDepthDataOutput(for: self.session)
        configureFrameRate()
        return .videoSuccess
    }

    private func checkSessionValidity(for input: AVCaptureDeviceInput) -> CameraSetupResult? {
        guard self.session.canAddInput(input) else {
            return .invalidVideoInput
        }
        guard self.session.canAddOutput(self.videoDataOutput) else {
            return .invalidVideoDataOutput
        }
        guard self.session.canAddOutput(self.photoOutput) else {
            return .invalidPhotoOutput
        }
        guard self.session.canAddOutput(self.metadataOutput) else {
            return .invalidVideoMetadataOutput
        }
        if self.recordsVideo == true {
            guard self.session.canAddOutput(self.videoFileOutput) else {
                return .invalidVideoFileOutput
            }
        }
        if #available(iOS 11.0, *), let depthDataOutput = self.depthDataOutput {
            guard self.session.canAddOutput(depthDataOutput) else {
                return .invalidDepthDataOutput
            }
        }
        return nil
    }

    private func configureVideoRecordingOutput(for session: AVCaptureSession) {
        if self.recordsVideo {
            // adding this invalidates the video data output
            self.session.addOutput(self.videoFileOutput)
            if let connection = self.videoFileOutput.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
            }
        }
    }

    private func configureHiResPhotoOutput(for session: AVCaptureSession) {
        if self.captureHighResolutionImages && self.photoOutput.isHighResolutionCaptureEnabled {
            self.photoOutput.isHighResolutionCaptureEnabled = true
        } else {
            self.captureHighResolutionImages = false
        }
    }

    private func configureLivePhotoOutput(for session: AVCaptureSession) {
        if self.captureLivePhotos && self.photoOutput.isLivePhotoCaptureSupported {
            self.photoOutput.isLivePhotoCaptureEnabled = true
        } else {
            self.captureLivePhotos = false
        }
    }

    private func configureMetadataOutput(for session: AVCaptureSession) {
        if self.trackMetadata {
            session.addOutput(self.metadataOutput)
            self.metadataOutput.metadataObjectTypes = self.metadataOutput.availableMetadataObjectTypes
        }
    }

    private func configureDepthDataOutput(for session: AVCaptureSession) {
        if #available(iOS 11.0, *) {
            if self.captureDepthData && self.photoOutput.isDepthDataDeliverySupported {
                self.photoOutput.isDepthDataDeliveryEnabled = true
            } else {
                self.captureDepthData = false
            }
        } else {
            self.captureDepthData = false
        }
        if #available(iOS 11.0, *) {
            if self.streamDepthData, let depthDataOutput = self.depthDataOutput {
                session.addOutput(depthDataOutput)
                session.commitConfiguration()
            }
        }
    }
}
