//
//  VideoCapture.swift
//
//  Created by Shuichi Tsutsumi on 4/3/16.
//  Copyright © 2016 Shuichi Tsutsumi. All rights reserved.
//

import AVFoundation
import Foundation


struct VideoSpec {
    var fps: Int32?
    var size: CGSize?
}

typealias ImageBufferHandler = (CVPixelBuffer, CMTime, CVPixelBuffer?) -> Void
typealias SynchronizedDataBufferHandler = (CVPixelBuffer, AVDepthData?, AVMetadataObject?) -> Void

extension AVCaptureDevice {
    func printDepthFormats() {
        formats.forEach { (format) in
            let depthFormats = format.supportedDepthDataFormats
            if depthFormats.count > 0 {
                print("format: \(format), supported depth formats: \(depthFormats)")
            }
        }
    }
}

class VideoCapture: NSObject {

    private let captureSession = AVCaptureSession()
    private var videoDevice: AVCaptureDevice!
    private var videoConnection: AVCaptureConnection!
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    private let dataOutputQueue = DispatchQueue(label: "com.shi.depthSampler.queue")

    var imageBufferHandler: ImageBufferHandler?
    var syncedDataBufferHandler: SynchronizedDataBufferHandler?

    // It is not called delegate unless it is retained in the property
    // AVCaptureDepthDataOutput is not in property（because it addOutput to CaptureSession）
    private var dataOutputSynchronizer: AVCaptureDataOutputSynchronizer!
    
    // Not necessary, but easy to retrieve data from AVCaptureSynchronizedDataCollection
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let depthDataOutput = AVCaptureDepthDataOutput()
    private let metadataOutput = AVCaptureMetadataOutput()

    //
    var outputFileLocation: URL!
    private var videoWriter: AVAssetWriter!
    private var videoWriterInput: AVAssetWriterInput!
    //private var audioWriterInput: AVAssetWriterInput!
    private var isRecording = false
    private var sessionAtSourceTime: CMTime?

    
    init(cameraType: CameraType, preferredSpec: VideoSpec?, previewContainer: CALayer?) {
        super.init()
        
        captureSession.beginConfiguration()
        
        // inputPriority can not be depth
        captureSession.sessionPreset = AVCaptureSession.Preset.photo
        
        setupCaptureVideoDevice(with: cameraType)
        
        // setup preview
        if let previewContainer = previewContainer {
            let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
            previewLayer.frame = previewContainer.bounds
            previewLayer.contentsGravity = CALayerContentsGravity.resizeAspectFill
            previewLayer.videoGravity = .resizeAspectFill
            previewContainer.insertSublayer(previewLayer, at: 0)
            self.previewLayer = previewLayer
        }
        
        // setup outputs
        do {
            // video output
            videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            videoDataOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)
            guard captureSession.canAddOutput(videoDataOutput) else { fatalError() }
            captureSession.addOutput(videoDataOutput)
            videoConnection = videoDataOutput.connection(with: .video)

            // depth output
            guard captureSession.canAddOutput(depthDataOutput) else { fatalError() }
            captureSession.addOutput(depthDataOutput)
            depthDataOutput.setDelegate(self, callbackQueue: dataOutputQueue)
            depthDataOutput.isFilteringEnabled = false
            guard let connection = depthDataOutput.connection(with: .depthData) else { fatalError() }
            connection.isEnabled = true
            
            // metadata output
            guard captureSession.canAddOutput(metadataOutput) else { fatalError() }
            captureSession.addOutput(metadataOutput)
            if metadataOutput.availableMetadataObjectTypes.contains(.face) {
                metadataOutput.metadataObjectTypes = [.face]
            }

            // synchronize outputs using func dataOutputSynchronizer() in extension from class AVCaptureDataOutputSynchronizerDelegate
            dataOutputSynchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoDataOutput, depthDataOutput, metadataOutput])
            dataOutputSynchronizer.setDelegate(self, queue: dataOutputQueue)
        }
        
        setupConnections(with: cameraType)
        
        captureSession.commitConfiguration()

        start()
    }
    
    private func setupCaptureVideoDevice(with cameraType: CameraType) {
        
        videoDevice = cameraType.captureDevice()
        print("selected video device: \(String(describing: videoDevice))")
        
        videoDevice.selectDepthFormat()

        captureSession.inputs.forEach { (captureInput) in
            captureSession.removeInput(captureInput)
        }
        let videoDeviceInput = try! AVCaptureDeviceInput(device: videoDevice)
        guard captureSession.canAddInput(videoDeviceInput) else { fatalError() }
        captureSession.addInput(videoDeviceInput)
    }
    
    private func setupConnections(with cameraType: CameraType) {
        videoConnection = videoDataOutput.connection(with: .video)!
        let depthConnection = depthDataOutput.connection(with: .depthData)
        switch cameraType {
        case .front:
            videoConnection.isVideoMirrored = true
            depthConnection?.isVideoMirrored = true
        default:
            break
        }
        videoConnection.videoOrientation = .portrait
        depthConnection?.videoOrientation = .portrait
    }
    
    func startCapture() {
        print("\(self.classForCoder)/" + #function)
        if captureSession.isRunning {
            print("already running")
            return
        }
        captureSession.startRunning()

        start()
    }
    
    func stopCapture() {
        print("\(self.classForCoder)/" + #function)
        if !captureSession.isRunning {
            print("already stopped")
            return
        }
        captureSession.stopRunning()

        stop()
    }
    
    func resizePreview() {
        if let previewLayer = previewLayer {
            guard let superlayer = previewLayer.superlayer else {return}
            previewLayer.frame = superlayer.bounds
        }
    }
    
    func changeCamera(with cameraType: CameraType) {
        let wasRunning = captureSession.isRunning
        if wasRunning {
            captureSession.stopRunning()

            stop()
        }
        captureSession.beginConfiguration()

        setupCaptureVideoDevice(with: cameraType)
        setupConnections(with: cameraType)
        
        captureSession.commitConfiguration()
        
        if wasRunning {
            start()

            captureSession.startRunning()
        }
    }

    func setDepthFilterEnabled(_ enabled: Bool) {
        depthDataOutput.isFilteringEnabled = enabled
    }

    func setUpWriter() {
        do {
            outputFileLocation = videoFileLocation()
            videoWriter = try AVAssetWriter(outputURL: outputFileLocation, fileType: AVFileType.mov)

            // add video input
            videoWriterInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: [
                AVVideoCodecKey : AVVideoCodecType.h264,
                AVVideoWidthKey : 720,
                AVVideoHeightKey : 1280,
                AVVideoCompressionPropertiesKey : [
                    AVVideoAverageBitRateKey : 2300000,
                ],
                ])

            videoWriterInput.expectsMediaDataInRealTime = false

            if videoWriter.canAdd(videoWriterInput) {
                videoWriter.add(videoWriterInput)
                print("video input added")
            } else {
                print("no input added")
            }

            // add audio input
            /*audioWriterInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: nil)

            audioWriterInput.expectsMediaDataInRealTime = true

            if videoWriter.canAdd(audioWriterInput!) {
                videoWriter.add(audioWriterInput!)
                print("audio input added")
            }*/


            videoWriter.startWriting()
        } catch let error {
            debugPrint(error.localizedDescription)
        }

    }

    func canWrite() -> Bool {
        return isRecording && videoWriter != nil && videoWriter?.status == .writing
    }

    //video file location method
    func videoFileLocation() -> URL {
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] as NSString
        let videoOutputUrl = URL(fileURLWithPath: documentsPath.appendingPathComponent("videoFile")).appendingPathExtension("mov")
        do {
            if FileManager.default.fileExists(atPath: videoOutputUrl.path) {
                try FileManager.default.removeItem(at: videoOutputUrl)
                print("file removed")
            }
        } catch {
            print(error)
        }

        return videoOutputUrl
    }

    // MARK: Start recording
    func start() {
        guard !isRecording else { return }
        isRecording = true
        sessionAtSourceTime = nil
        setUpWriter()
        print(isRecording)
        print(videoWriter)
        if videoWriter.status == .writing {
            print("status writing")
        } else if videoWriter.status == .failed {
            print("status failed")
        } else if videoWriter.status == .cancelled {
            print("status cancelled")
        } else if videoWriter.status == .unknown {
            print("status unknown")
        } else {
            print("status completed")
        }

    }

    // MARK: Stop recording
    func stop() {
        guard isRecording else { return }
        isRecording = false
        videoWriterInput.markAsFinished()
        print("marked as finished")
        videoWriter.finishWriting { [weak self] in
            self?.sessionAtSourceTime = nil
        }
        //print("finished writing \(self.outputFileLocation)")
        captureSession.stopRunning()
        //performSegue(withIdentifier: "videoPreview", sender: nil)
    }
}

extension VideoCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    //func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
//        print("\(self.classForCoder)/" + #function)
    //}
    
    // Not called when using synchronizer
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let imageBufferHandler = imageBufferHandler, connection == videoConnection
        {
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { fatalError() }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            imageBufferHandler(imageBuffer, timestamp, nil)
        }
    }
}

extension VideoCapture: AVCaptureDepthDataOutputDelegate {
    
    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didDrop depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection, reason: AVCaptureOutput.DataDroppedReason) {
        print("\(self.classForCoder)/\(#function)")
    }
    
    // Not called when using synchronizer
    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection) {
        print("\(self.classForCoder)/\(#function)")
    }
}

extension VideoCapture: AVCaptureDataOutputSynchronizerDelegate {
    
    // Called when an AVCaptureDataOutputSynchronizer instance outputs synchronized data from one or more data outputs.
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer, didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        
        guard let syncedVideoData = synchronizedDataCollection.synchronizedData(for: videoDataOutput) as? AVCaptureSynchronizedSampleBufferData else { return }
        guard !syncedVideoData.sampleBufferWasDropped else {
            print("dropped video:\(syncedVideoData)")
            return
        }
        let videoSampleBuffer = syncedVideoData.sampleBuffer

        let syncedDepthData = synchronizedDataCollection.synchronizedData(for: depthDataOutput) as? AVCaptureSynchronizedDepthData
        var depthData = syncedDepthData?.depthData
        if let syncedDepthData = syncedDepthData, syncedDepthData.depthDataWasDropped {
            print("dropped depth:\(syncedDepthData)")
            depthData = nil
        }

        // Find the threshold of a position with a face
        let syncedMetaData = synchronizedDataCollection.synchronizedData(for: metadataOutput) as? AVCaptureSynchronizedMetadataObjectData
        var face: AVMetadataObject? = nil
        if let firstFace = syncedMetaData?.metadataObjects.first {
            face = videoDataOutput.transformedMetadataObject(for: firstFace, connection: videoConnection)
        }
        guard let imagePixelBuffer = CMSampleBufferGetImageBuffer(videoSampleBuffer) else { fatalError() }

        syncedDataBufferHandler?(imagePixelBuffer, depthData, face)

        //////////////////////////////////////////

        let writable = canWrite()
        if !writable {
            return
        }

        guard let depthPixelBuffer = depthData?.depthDataMap else { return }
        let pixelBuffer = depthPixelBuffer

        var formatDesc: CMFormatDescription? = nil
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc)

        var info = CMSampleTimingInfo()
        info.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(videoSampleBuffer)//CMTime.zero
        info.duration = CMSampleBufferGetDuration(videoSampleBuffer)//CMTime.invalid
        info.decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(videoSampleBuffer) //CMTime.invalid

        var sampleBuffer: CMSampleBuffer? = nil

        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDesc!,
            sampleTiming: &info,
            sampleBufferOut: &sampleBuffer)

        if writable,
            sessionAtSourceTime == nil {
            // start writing
            sessionAtSourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer!)
            videoWriter.startSession(atSourceTime: sessionAtSourceTime!)
            print("Writing")
        }

        /*if output == videoDataOutput {
            connection.videoOrientation = .portrait

            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
        }*/

        if writable,
            /*output == videoDataOutput,*/
            (videoWriterInput.isReadyForMoreMediaData) {
            // write video buffer
            videoWriterInput.append(sampleBuffer!)
            print("video buffering")
            if videoWriter?.error != nil {
                print ("video writer error: \(videoWriter?.error!)")
            }
        }/* else if writable,
         output == audioDataOutput,
         (audioWriterInput.isReadyForMoreMediaData) {
         // write audio buffer
         audioWriterInput?.append(sampleBuffer)
         //print("audio buffering")
         }*/
    }
}
