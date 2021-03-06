//
//  RealtimeDepthViewController.swift
//
//  Created by yanshi on 2019/01/20.
//  Copyright © 2018 Shuichi Tsutsumi. All rights reserved.
//

import UIKit
import MetalKit
import AVFoundation

class RealtimeDepthViewController: UIViewController {
    
    // MARK: Properties
    // previewView and mtkView are displayed on UI, previewView is raw BGRA video in AVCaptureSession, mtkView is processed depth frames visualized by MetalRenderer.
    @IBOutlet weak var previewView: UIView!
    @IBOutlet weak var mtkView: MTKView!
    @IBOutlet weak var filterSwitch: UISwitch!
    @IBOutlet weak var disparitySwitch: UISwitch!
    @IBOutlet weak var equalizeSwitch: UISwitch!

    private var videoCapture: VideoCapture!
    var currentCameraType: CameraType = .front(true)
    private let serialQueue = DispatchQueue(label: "com.shi.depthSampler.queue")

    private var renderer: MetalRenderer!
    private var depthImage: CIImage?
    private var currentDrawableSize: CGSize!

    private var videoImage: CIImage?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let device = MTLCreateSystemDefaultDevice()!
        mtkView.device = device
        mtkView.backgroundColor = UIColor.clear
        mtkView.delegate = self
        renderer = MetalRenderer(metalDevice: device, renderDestination: mtkView)
        currentDrawableSize = mtkView.currentDrawable!.layer.drawableSize

        videoCapture = VideoCapture(cameraType: currentCameraType,
                                    preferredSpec: nil,
                                    previewContainer: previewView.layer)
        
        // Inline implement main statement of closure. (CVPixelBuffer, AVDepthData?, AVMetadataObject?) -> Void
        videoCapture.syncedDataBufferHandler = { [weak self] videoPixelBuffer, depthData, face in
            guard let self = self else { return }
            
            // Receive image frame from VideoCapture to self.videoImage
            self.videoImage = CIImage(cvPixelBuffer: videoPixelBuffer)

            var useDisparity: Bool = false
            var applyHistoEq: Bool = false
            DispatchQueue.main.sync(execute: {
                useDisparity = self.disparitySwitch.isOn
                applyHistoEq = self.equalizeSwitch.isOn
            })
            
            // Receive depth frame frome VideoCapture to self.depthImage
            self.serialQueue.async {
                // Original depthData here
                guard let depthData = useDisparity ? depthData?.convertToDisparity() : depthData else { return }
                
                guard let ciImage = depthData.depthDataMap.transformedImage(targetSize: self.currentDrawableSize, rotationAngle: 0) else { return }
                self.depthImage = applyHistoEq ? ciImage.applyingFilter("YUCIHistogramEqualization") : ciImage
            }
        }
        videoCapture.setDepthFilterEnabled(filterSwitch.isOn)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard let videoCapture = videoCapture else {return}
        videoCapture.startCapture()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let videoCapture = videoCapture else {return}
        videoCapture.resizePreview()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        guard let videoCapture = videoCapture else {return}
        videoCapture.imageBufferHandler = nil
        videoCapture.stopCapture()
        mtkView.delegate = nil
        super.viewWillDisappear(animated)
    }

    @IBAction func shareVideo(_ sender: UIButton) {
        guard let videoCapture = videoCapture else {return}

        if (mtkView.delegate != nil) {
            videoCapture.imageBufferHandler = nil
            videoCapture.stopCapture()
            mtkView.delegate = nil
        }

        let videoLink = videoCapture.outputFileLocation

        let objectsToShare = [videoLink] //comment!, imageData!, myWebsite!]
        let activityVC = UIActivityViewController(activityItems: objectsToShare, applicationActivities: nil)

        activityVC.setValue("Video", forKey: "subject")


        //New Excluded Activities Code
        activityVC.excludedActivityTypes = [
            UIActivity.ActivityType.airDrop,
            UIActivity.ActivityType.addToReadingList,
            UIActivity.ActivityType.assignToContact,
            UIActivity.ActivityType.copyToPasteboard,
            UIActivity.ActivityType.mail,
            UIActivity.ActivityType.message,
            UIActivity.ActivityType.openInIBooks,
            UIActivity.ActivityType.postToTencentWeibo,
            UIActivity.ActivityType.postToVimeo,
            UIActivity.ActivityType.postToWeibo,
            UIActivity.ActivityType.print]


        self.present(activityVC, animated: true, completion: nil)
    }

    // MARK: Actions
    
    @IBAction func cameraSwitchBtnTapped(_ sender: UIButton) {
        switch currentCameraType {
        case .back:
            currentCameraType = .front(true)
        case .front:
            currentCameraType = .back(true)
        }
        videoCapture.changeCamera(with: currentCameraType)
    }
    
    @IBAction func filterSwitched(_ sender: UISwitch) {
        videoCapture.setDepthFilterEnabled(sender.isOn)
    }
}

extension RealtimeDepthViewController: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        currentDrawableSize = size
    }
    
    func draw(in view: MTKView) {
        if let image = depthImage {
            renderer.update(with: image)
        }
    }
}
