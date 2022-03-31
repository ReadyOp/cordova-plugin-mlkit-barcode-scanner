/*
 Copyright 2016-present Google Inc. All Rights Reserved.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

@import AVFoundation;
@import MLKitBarcodeScanning;
@import MLKitVision;

#import "CameraViewController.h"

@interface CameraViewController ()<AVCaptureVideoDataOutputSampleBufferDelegate>

@property(nonatomic, weak) IBOutlet UIView *placeHolderView;
@property(nonatomic, weak) IBOutlet UIView *overlayView;
@property(nonatomic, strong) UILabel *reticle;

@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureVideoDataOutput *videoDataOutput;
@property(nonatomic, strong) dispatch_queue_t videoDataOutputQueue;
@property(nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;

@property(nonatomic, strong) MLKBarcodeScanner *barcodeDetector;
@property(nonatomic, strong) UIButton *torchButton;

@end

@implementation CameraViewController
@synthesize delegate;

- (BOOL)prefersStatusBarHidden
{
    return YES;
}

- (BOOL)prefersHomeIndicatorAutoHidden
{
    return YES;
}

- (BOOL) shouldAutorotate
{
    return NO;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskPortrait;
}

- (id)initWithCoder:(NSCoder *)aDecoder {
    self = [super initWithCoder:aDecoder];
    if (self) {
        _videoDataOutputQueue = dispatch_queue_create("VideoDataOutputQueue",
                                                      DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // Set up camera.
    self.session = [[AVCaptureSession alloc] init];
    if ([self.session canSetSessionPreset:AVCaptureSessionPreset3840x2160]) {
        self.session.sessionPreset = AVCaptureSessionPreset3840x2160;
    } else if ([self.session canSetSessionPreset:AVCaptureSessionPresetHigh]) {
        self.session.sessionPreset = AVCaptureSessionPresetHigh;
    } else if ([self.session canSetSessionPreset:AVCaptureSessionPresetMedium]) {
        self.session.sessionPreset = AVCaptureSessionPresetMedium;
    }

    _videoDataOutputQueue = dispatch_queue_create("VideoDataOutputQueue",
                                                  DISPATCH_QUEUE_SERIAL);

    [self updateCameraSelection];

    // Set up video processing pipeline.
    [self setUpVideoProcessing];

    // Set up camera preview.
    [self setUpCameraPreview];

    //Parse Cordova settings.
    NSNumber *formats = 0;
    //If barcodeFormats == 0 then process as a VIN with VIN verifications.
    if([_barcodeFormats  isEqual: @0]) {
        NSLog(@"Running VIN style");
        formats = @(MLKBarcodeFormatCode39|MLKBarcodeFormatDataMatrix);
    } else if([_barcodeFormats  isEqual: @1234]) {
        // @todo: investigating what should be done here
    } else {
        formats = _barcodeFormats;
    }
    NSLog(@"_barcodeFormats %@, %@", _barcodeFormats, formats);

    // Initialize barcode detector.
    MLKBarcodeScannerOptions *options = [[MLKBarcodeScannerOptions alloc] initWithFormats: [formats intValue]];
    self.barcodeDetector = [MLKBarcodeScanner barcodeScannerWithOptions:options];
}

-(UIImageOrientation)imageOrientationFromDeviceOrientation:(UIDeviceOrientation)deviceOrientation cameraPosition:(AVCaptureDevicePosition)cameraPosition {
  switch (deviceOrientation) {
    case UIDeviceOrientationPortrait:
      return cameraPosition == AVCaptureDevicePositionFront ? UIImageOrientationLeftMirrored
                                                            : UIImageOrientationRight;

    case UIDeviceOrientationLandscapeLeft:
      return cameraPosition == AVCaptureDevicePositionFront ? UIImageOrientationDownMirrored
                                                            : UIImageOrientationUp;
    case UIDeviceOrientationPortraitUpsideDown:
      return cameraPosition == AVCaptureDevicePositionFront ? UIImageOrientationRightMirrored
                                                            : UIImageOrientationLeft;
    case UIDeviceOrientationLandscapeRight:
      return cameraPosition == AVCaptureDevicePositionFront ? UIImageOrientationUpMirrored
                                                            : UIImageOrientationDown;
    case UIDeviceOrientationUnknown:
    case UIDeviceOrientationFaceUp:
    case UIDeviceOrientationFaceDown:
      return UIImageOrientationUp;
  }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    self.previewLayer.frame = self.view.layer.bounds;
    self.previewLayer.position = CGPointMake(CGRectGetMidX(self.previewLayer.frame),
                                             CGRectGetMidY(self.previewLayer.frame));
}

- (void)dealloc {
    [self cleanupCaptureSession];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    AVAuthorizationStatus authStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (authStatus == AVAuthorizationStatusDenied) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Camera permission required" message:@"Access to the camera has been prohibited, please enable it in the settings to continue." preferredStyle:UIAlertControllerStyleAlert];
        
        UIAlertAction *primaryAction = [UIAlertAction actionWithTitle:@"Settings" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil];
            [self.delegate closeScanner];
        }];
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            [self.delegate closeScanner];
        }];
        [alert addAction:cancelAction];
        [alert addAction:primaryAction];
        alert.preferredAction = primaryAction;
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        //Force portrait orientation.
        [[UIDevice currentDevice] setValue:
         [NSNumber numberWithInteger: UIInterfaceOrientationPortrait]
                                    forKey:@"orientation"];
        
        [self.session startRunning];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.session stopRunning];
}


#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (CGRect)convertRectOfInterest: (CGRect)rect
{
    CGRect overlayRect = self.view.bounds;
    CGSize overlaySize = overlayRect.size;

    CGFloat x = 1 / (overlaySize.width / rect.origin.x);
    CGFloat y = 1 / (overlaySize.height / rect.origin.y);
    CGFloat w = 1 / (overlaySize.width / rect.size.width);
    CGFloat h = 1 / (overlaySize.height / rect.size.height);

    return CGRectMake(x, y, w, h);
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {

    // Figure out the image orientation
    AVCaptureDevice *device = [[[self.session inputs] firstObject] device];
    AVCaptureDevicePosition cameraPosition = [device position];
    UIImageOrientation orientation = [self imageOrientationFromDeviceOrientation: UIDevice.currentDevice.orientation cameraPosition: cameraPosition];

    // Get the raw image buffer and it's dimensions
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CGFloat imageWidth = CVPixelBufferGetWidth(imageBuffer);
    CGFloat imageHeight = CVPixelBufferGetHeight(imageBuffer);

    // Configure the crop rectangle, we crop the image to only what's within the reticle view, for faster processing
    CGRect interest = [self convertRectOfInterest: self.reticle.frame];
    CGRect cropRect;
    if (orientation == UIImageOrientationRight || orientation == UIImageOrientationRightMirrored || orientation == UIImageOrientationLeft || orientation == UIImageOrientationLeftMirrored) {
        cropRect = CGRectMake(imageWidth * interest.origin.y, imageHeight * interest.origin.x, imageWidth * interest.size.height, imageHeight * interest.size.width);
    } else {
        cropRect = CGRectMake(imageWidth * interest.origin.x, imageHeight * interest.origin.y, imageWidth * interest.size.width, imageHeight * interest.size.height);
    }

    //Convert sampleBuffer into an image.
    //MLKVisionImage *image = [[MLKVisionImage alloc] initWithBuffer:sampleBuffer];
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
    CIContext *temporaryContext = [CIContext contextWithOptions:nil];
    CGImageRef videoImage = [temporaryContext createCGImage:ciImage fromRect: cropRect];

    UIImage *image = [[UIImage alloc] initWithCGImage:videoImage];
    CGImageRelease(videoImage);

    // Setup the image for the MLK
    MLKVisionImage *visionImage = [[MLKVisionImage alloc] initWithImage:image];
    visionImage.orientation = orientation;

    //Send the image through the barcode reader.
    [self.barcodeDetector processImage: visionImage completion:^(NSArray<MLKBarcode *> *barcodes, NSError *error) {
        if (error != nil) {
            return;
        } else if (barcodes != nil) {
            for (MLKBarcode *barcode in barcodes) {
                NSLog(@"Barcode value: %@", barcode.rawValue);
                [self cleanupCaptureSession];
                [self->_session stopRunning];
                [self->delegate sendResult:barcode];
                break;
            }
        }
    }];

}

#pragma mark - Camera setup

- (void)cleanupVideoProcessing {
    if (self.videoDataOutput) {
        [self.session removeOutput:self.videoDataOutput];
    }
    self.videoDataOutput = nil;
}

- (void)cleanupCaptureSession {
    [self.session stopRunning];
    [self cleanupVideoProcessing];
    self.session = nil;
    [self.previewLayer removeFromSuperlayer];
}

- (void)setUpVideoProcessing {
    self.videoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
    NSDictionary *rgbOutputSettings = @{
        (__bridge NSString*)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)
    };
    [self.videoDataOutput setVideoSettings:rgbOutputSettings];

    if (![self.session canAddOutput:self.videoDataOutput]) {
        [self cleanupVideoProcessing];
        NSLog(@"Failed to setup video output");
        return;
    }
    [self.videoDataOutput setAlwaysDiscardsLateVideoFrames:YES];
    [self.videoDataOutput setSampleBufferDelegate:self queue:self.videoDataOutputQueue];
    [self.session addOutput:self.videoDataOutput];
}

- (void)setUpCameraPreview {
    self.previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:self.session];
    [self.previewLayer setBackgroundColor:[UIColor blackColor].CGColor];
    [self.previewLayer setVideoGravity:AVLayerVideoGravityResizeAspectFill];

    self.previewLayer.frame = self.view.superview.bounds;
    [self.view.layer addSublayer:self.previewLayer];

    CGRect screenRect = [[UIScreen mainScreen] bounds];
    CGFloat screenWidth = screenRect.size.width;
    CGFloat screenHeight = screenRect.size.height;

    CGFloat frameWidth = screenWidth * _detectorSize;
    CGFloat frameHeight = frameWidth;

    self.reticle = [[UILabel alloc] init];
    self.reticle.frame = CGRectMake(screenWidth/2 - frameWidth/2, screenHeight/2 - frameHeight/2, frameWidth, frameHeight);
    self.reticle.layer.masksToBounds = NO;
    self.reticle.layer.cornerRadius = 30;
    self.reticle.userInteractionEnabled = YES;
    self.reticle.layer.borderColor = [UIColor whiteColor].CGColor;
    self.reticle.layer.borderWidth = 3.0;
    UITapGestureRecognizer *tapScanner = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(focusAtPoint:)];
    [self.reticle addGestureRecognizer:tapScanner];

    CGFloat buttonSize = 45.0;

    UIButton *_cancelButton = [[UIButton alloc] init];
    [_cancelButton addTarget:self
                      action:@selector(closeView:)
            forControlEvents:UIControlEventTouchUpInside];

    NSString * cancelBase64String = @"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAQAAABpN6lAAAAABGdBTUEAALGPC/xhBQAAACBjSFJNAAB6JgAAgIQAAPoAAACA6AAAdTAAAOpgAAA6mAAAF3CculE8AAAAAmJLR0QAAKqNIzIAAAAJcEhZcwAADdcAAA3XAUIom3gAAAAHdElNRQfhCxMVEyaNvw4TAAADNElEQVR42u2dv1LqQBSHv1DwBjY0FjyAA7wCtna2ttrwLr6GY4PWKfQBJGNtb2PDMFQ2ewvmDheBC0l295zjYVO6Cb/vC4b82c0p+Lf1GDNkwAVfzKh4oyRguxWMGTFgyBnvVMwo+dzd8Y4F4cfyQl+aoFXr87LFtOCW4mfHc8qtjqtlyWS7u4lWMGG5h6rkfBN/vqfjapnSlaap3bpM/8s0Xyso9u799fJkTEGXp4NM5d9v9t3BrtYUHIMfCNwC9HYc+mwrOBY/sKAHN0d2tqLgePxA4Abua3TXr6AefuAeXmutoFtBXfzAKwd+AC0pqI8fmMNH7ZV0KmiCH/iAhwar6VPQDD/w0KFq9IFXPCpS0OWRq0ZrVnDZyJymb0HTvR8IXEKx43rJkoI2+C+rk+H+3msm/Qra4C/Xl/qTxhuRVdAGPzBZb6g4cOmoU0E7/OnmXY52G5NQED2xLQVJ0tpRkCypDQVJU+pXkDyhbgVZ0ulVkC2ZTgVZU+lTkD2RLgUiafQoEEuiQ4FoCnkF4glkA4jjy4ZQgS8XRA2+TBhV+PkDqcPPG0olfr5gavHzhFONnz6gevy0IU3gpwtqBj9NWFP48QObw48b2iR+vOBm8eOEN40fQ4Fx/PYKzONLKVCEL6FAGX5uBQrxcypQip9LgWL8HAqU46dWYAA/pQIj+KkUGMJPocAYfmwFBvFjKjCKH0uBYfwYCpLjd6QN/e7m/F/A+UHQ+c+g8xMh56fCzi+GnF8OO78h4vyWmPObos5vizt/MOL80Zjzh6POH487HyDhfIiM80FSzofJOR8o6XyorPPB0s6HyzufMOF8yozzSVPOp805nzjpfOqs88nTzqfPiwfw/v4I0RQ68MWS6MEXSaMLP3siffhZU+nEz5ZML36WdLrxkyfUj580pQ38ZEnt4CdJaws/emL3r9Z2/nJ156/Xd19gwXmJjQ6jhh/7zDXf0uwAfHPNc8N1R+7L7JwKLZ1KbTkvtla30pSeQ9+uVv9wWJ0KLp5Kbrovunoqu4v7wssrBa5Lb6+6uyy+vrlve4wZMuCCL2ZUvFESpBlatoIxIwYMOeOdihkln+s//wFFdoCM42fEswAAACV0RVh0ZGF0ZTpjcmVhdGUAMjAxNy0xMS0xOVQyMToxOTozOCswMTowMPNH2M8AAAAldEVYdGRhdGU6bW9kaWZ5ADIwMTctMTEtMTlUMjE6MTk6MzgrMDE6MDCCGmBzAAAAGXRFWHRTb2Z0d2FyZQB3d3cuaW5rc2NhcGUub3Jnm+48GgAAAABJRU5ErkJggg==";

    NSURL *cancelImageUrl = [NSURL URLWithString:cancelBase64String];
    NSData *cancelImageData = [NSData dataWithContentsOfURL:cancelImageUrl];
    UIImage *cancelIcon = [UIImage imageWithData:cancelImageData];
    [_cancelButton setImage:cancelIcon
                   forState:UIControlStateNormal];

    CGFloat screenOffset = (screenWidth/2 - frameWidth/2)/2 - buttonSize/2;
    NSLog(@"screenOffset %f", screenOffset);

    _cancelButton.frame = CGRectMake(buttonSize / 2, screenHeight - buttonSize - (buttonSize / 2), buttonSize, buttonSize);
    _cancelButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.4];
    _cancelButton.transform=CGAffineTransformMakeRotation(M_PI / 2);
    _cancelButton.layer.cornerRadius = buttonSize/2;
    _cancelButton.contentEdgeInsets = UIEdgeInsetsMake(15, 15, 15, 15);

    [self.view addSubview:_cancelButton];




    self.torchButton = [[UIButton alloc] init];
    [self.torchButton addTarget:self
                         action:@selector(toggleFlashlight:)
               forControlEvents:UIControlEventTouchUpInside];

    NSString * torchBase64String = @"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAQAAABpN6lAAAAABGdBTUEAALGPC/xhBQAAACBjSFJNAAB6JgAAgIQAAPoAAACA6AAAdTAAAOpgAAA6mAAAF3CculE8AAAAAmJLR0QAAKqNIzIAAAAJcEhZcwAADdcAAA3XAUIom3gAAAAHdElNRQfhCxMVAzOqoPipAAADM0lEQVR42u2dv2sTcRyG38RWzGYHhxYHp+B+Lk7iIlhFXZvdPeAouOuS1X/AVCiiCBU6OjgIOffG+gvEgCIqlsQi9JxEbC/XJt8fz136eTJecve+T+6Su8t9czX5oqmWEiVa9DbHfAZKlaqrfuDlTERNbQ2VRXwM1VaNrv2v/nrU8n8f62VR0EbqZ8rUpqtLUjPyyv//htB0jV93FrCiBia/oRYv4BxWX5IS1xm4f4x8Cv7FV8RAS7SADKzvoYH7JlBxTAAdgMYE0AFoTAAdwDAMwzAMo7q8ws4IZsr0wjW++57gFqrfeenuAt6YAJLXvADbBFABJVgDPmobrP+DF5BpAxPwyH0WPk6IPKmyAB8/MJ/UZ80D9T/ojPtMfKwB3/UcqO/l/fd1TvAxIuAhstRclrQT/ShgzU/0Y17m8lMLOh9V+UjX3L8CfbKgr1Hf/zt04f3EvFLorU7QdfdzXFuR6v/SRbpsPjci1b9MFx3P7eD1d3SFLlnM3cD1r9IFD+Z+wJW/AvWluh4EqT/UJbraYZnTmvf627pA12IV3KQrTa7gqcf6z+g603BKXzzV/+Z6NSjFiicB9+gi07PhRcBZusb0XPdQ3/nXP5J5D58Dt8JGDHuZ3G8Pp60C//AS+jrBl85zeBc24FxgAe/HTulrVT2lkhIlao0d/RNYQGhO527Xu+rsGWnUUEe7uc+tOPXc+su5z13OVVB59lfqjH1u5ygI2CwYZtfQZmwB8a8WX9Vo7LSRurHjxBfQK5yaRs8TnL2rdPEow8XZ3wRKRnwBicPUmRBQPNY4uoDwlPxrML6AI78jZLvC5ToYCv83JOMqHPZwOHBCTkBJEtqOEB2AxgTQAWhMAB2AxgTQAWhMAB2AxgTQAWhMAB2AxgTQAWhMAB2AxgTQAWhMAB2AxgTQAWhMAB2AxgTQAWhMAB2AxgTQAWhMAB2AxgTQAWhMAB2AxgTQAWhMAB2AxgTQAWhMAB2AxgQEX8IAfHUpBLgNhg0+lDa8gJ7Tq2dgLLHLbXk93Fa3DEz/d6ttOrofpr01d2lure1DwaQ3Z492c/V4jptqKVFy4F2KB0qVqqt+nFh/ADjJgLiaxweIAAAAJXRFWHRkYXRlOmNyZWF0ZQAyMDE3LTExLTE5VDIxOjAzOjUxKzAxOjAwdhzbkgAAACV0RVh0ZGF0ZTptb2RpZnkAMjAxNy0xMS0xOVQyMTowMzo1MSswMTowMAdBYy4AAAAZdEVYdFNvZnR3YXJlAHd3dy5pbmtzY2FwZS5vcmeb7jwaAAAAAElFTkSuQmCCconv";

    NSURL *torchImageUrl = [NSURL URLWithString:torchBase64String];
    NSData *torchImageData = [NSData dataWithContentsOfURL:torchImageUrl];
    UIImage *torchIcon = [UIImage imageWithData:torchImageData];
    [self.torchButton setImage:torchIcon
                      forState:UIControlStateNormal];

    self.torchButton.frame = CGRectMake(screenWidth - buttonSize - (buttonSize / 2), screenHeight - buttonSize - (buttonSize / 2), buttonSize, buttonSize);
    self.torchButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.4];
    self.torchButton.transform=CGAffineTransformMakeRotation(M_PI / 2);
    self.torchButton.layer.cornerRadius = buttonSize/2;
    self.torchButton.contentEdgeInsets = UIEdgeInsetsMake(10, 10, 10, 10);

    [self.view addSubview:self.torchButton];

    [self.view addSubview:self.reticle];
}

#pragma mark - Helper Functions

- (void)focusAtPoint:(id) sender {
    NSLog(@"captured touch");
    CGPoint touchPoint = [(UITapGestureRecognizer*)sender locationInView:self.view];
    double focus_x = touchPoint.x/self.previewLayer.frame.size.width;
    double focus_y = (touchPoint.y+66)/self.previewLayer.frame.size.height;

    NSError *error;
    NSArray *devices = [AVCaptureDevice devices];
    for (AVCaptureDevice *device in devices){
        NSLog(@"Device name: %@", [device localizedName]);
        if ([device hasMediaType:AVMediaTypeVideo]) {
            if ([device position] == AVCaptureDevicePositionBack) {
                NSLog(@"Device position : back");
                CGPoint point = CGPointMake(focus_y, 1-focus_x);
                if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus] && [device lockForConfiguration:&error]){
                    [device setFocusPointOfInterest:point];

                    for (UIView *subView in self.view.subviews)
                    {
                        if (subView.tag == 99)
                        {
                            [subView removeFromSuperview];
                        }
                    }

                    CGRect rect = CGRectMake(touchPoint.x-30, touchPoint.y-30, 60, 60);
                    UIView *focusRect = [[UIView alloc] initWithFrame:rect];
                    focusRect.layer.borderColor = [UIColor colorWithRed:0.98 green:0.80 blue:0.18 alpha:.7].CGColor;
                    focusRect.layer.borderWidth = 1;
                    focusRect.tag = 99;
                    [self.view addSubview:focusRect];

                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        [focusRect removeFromSuperview];
                    });

                    [device setFocusMode:AVCaptureFocusModeAutoFocus];
                    [device unlockForConfiguration];
                }
            }
        }
    }
}

- (void) toggleFlashlight:(id)sender
{
    // check if flashlight available
    Class captureDeviceClass = NSClassFromString(@"AVCaptureDevice");
    if (captureDeviceClass != nil) {
        AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        AVCapturePhotoSettings *photosettings = [AVCapturePhotoSettings photoSettings];
        if ([device hasTorch] && [device hasFlash]){

            [device lockForConfiguration:nil];
            if (device.torchMode == AVCaptureTorchModeOff)
            {
                self.torchButton.backgroundColor = [UIColor colorWithWhite:1 alpha:1];
                [device setTorchMode:AVCaptureTorchModeOn];
                photosettings.flashMode = AVCaptureFlashModeOn;
                //torchIsOn = YES;
            }
            else
            {
                self.torchButton.backgroundColor = [UIColor colorWithWhite:1 alpha:.4];
                [device setTorchMode:AVCaptureTorchModeOff];
                photosettings.flashMode = AVCaptureFlashModeOff;
                // torchIsOn = NO;
            }
            [device unlockForConfiguration];
        }
    } }

- (void)closeView:(id)sender{
    [ self cleanupCaptureSession];
    [_session stopRunning];
    [delegate closeScanner];
}


- (void)updateCameraSelection {
    [self.session beginConfiguration];

    // Remove old inputs
    NSArray *oldInputs = [self.session inputs];
    for (AVCaptureInput *oldInput in oldInputs) {
        [self.session removeInput:oldInput];
    }

    AVCaptureDevicePosition desiredPosition = AVCaptureDevicePositionBack;
    AVCaptureDeviceInput *input = [self captureDeviceInputForPosition:desiredPosition];
    if (!input) {
        // Failed, restore old inputs
        for (AVCaptureInput *oldInput in oldInputs) {
            [self.session addInput:oldInput];
        }
    } else {
        // Succeeded, set input and update connection states
        [self.session addInput:input];
    }

    // set focus params if available to improve focusing
    NSError* error = nil;
    AVCaptureDevice *device = [input device];
    [device lockForConfiguration:&error];
    if (error == nil) {
        if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
            [device setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
        }
        if ([device isAutoFocusRangeRestrictionSupported]) {
            [device setAutoFocusRangeRestriction:AVCaptureAutoFocusRangeRestrictionNear];
        }
    }
    [device unlockForConfiguration];

    [self.session commitConfiguration];
}

- (AVCaptureDeviceInput *)captureDeviceInputForPosition:(AVCaptureDevicePosition)desiredPosition {
    for (AVCaptureDevice *device in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
        if (device.position == desiredPosition) {
            NSError *error = nil;
            AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device
                                                                                error:&error];
            if (error) {
                NSLog(@"Could not initialize for AVMediaTypeVideo for device %@", device);
            } else if ([self.session canAddInput:input]) {
                return input;
            }
        }
    }
    return nil;
}



@end
