import CoreImage
import CoreVideo
import Foundation

struct RemoteCameraEffectsSettings: Equatable {
    var automaticLowLight = true
    var brightness: Float = 0
    var contrast: Float = 1
    var highlights: Float = 0
    var shadows: Float = 0
    var whites: Float = 0
    var blacks: Float = 0
    var temperature: Float = 0
    var tint: Float = 0
    var saturation: Float = 0
    var vibrance: Float = 0
    var filmGrain: Float = 0
    var chromaticAberration: Float = 0
    var vignette: Float = 0
    var monochrome = false
}

final class RemoteCameraEffects {
    private let width: Int
    private let height: Int
    private let context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var outputPool: CVPixelBufferPool?
    private var luminanceFrame = 0
    private var smoothedExposureEV: Float = 0
    private var previousDenoisedFrame: CIImage?
    private var randomOffset: CGFloat = 0
    private let settingsLock = NSLock()
    private var storedSettings = RemoteCameraEffectsSettings()

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &outputPool)
    }

    func update(_ settings: RemoteCameraEffectsSettings) {
        settingsLock.lock()
        storedSettings = settings
        settingsLock.unlock()
    }

    func process(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard let outputPool else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPool, &output) == kCVReturnSuccess,
              let output else { return nil }

        let input = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        updateLuminance(from: input, extent: extent)
        settingsLock.lock()
        let settings = storedSettings
        settingsLock.unlock()
        var image = input

        if smoothedExposureEV > 0.005 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: smoothedExposureEV
            ])
        }
        if smoothedExposureEV > 0.01 {
            image = image.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.02 + 0.055 * smoothedExposureEV,
                "inputSharpness": 0.4
            ])
            image = applyTemporalDenoise(image, amount: min(0.28, 0.08 + 0.12 * smoothedExposureEV))
        }

        if settings.brightness != 0 {
            let brightnessScale = max(0, 1 + settings.brightness)
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(brightnessScale), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(brightnessScale), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(brightnessScale), w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        }
        if settings.contrast != 1 || settings.saturation != 0 || settings.monochrome {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: 0,
                kCIInputContrastKey: settings.contrast,
                kCIInputSaturationKey: settings.monochrome ? 0 : max(0, 1 + settings.saturation)
            ])
        }
        if settings.highlights != 0 || settings.shadows != 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": max(0, min(1, 1 - settings.highlights)),
                "inputShadowAmount": max(0, min(1, settings.shadows))
            ])
        }
        if settings.whites != 0 || settings.blacks != 0 {
            image = applyBlackAndWhitePoints(image, whites: settings.whites, blacks: settings.blacks)
        }
        if settings.temperature != 0 || settings.tint != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(
                    x: CGFloat(6500 + settings.temperature * 1800),
                    y: CGFloat(settings.tint * 100)
                )
            ])
        }
        if settings.vibrance != 0 {
            image = image.applyingFilter("CIVibrance", parameters: [
                "inputAmount": settings.vibrance
            ])
        }

        if settings.chromaticAberration > 0 {
            image = applyChromaticAberration(image, amount: settings.chromaticAberration, extent: extent)
        }
        if settings.vignette > 0 {
            image = image.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: settings.vignette,
                kCIInputRadiusKey: CGFloat(min(width, height)) * 0.72
            ])
        }
        if settings.filmGrain > 0 {
            image = applyFilmGrain(image, amount: settings.filmGrain, extent: extent)
        }

        image = image.cropped(to: extent)
        context.render(image, to: output, bounds: extent, colorSpace: colorSpace)
        previousDenoisedFrame = image
        return output
    }

    private func updateLuminance(from image: CIImage, extent: CGRect) {
        luminanceFrame += 1
        settingsLock.lock()
        let automaticLowLight = storedSettings.automaticLowLight
        settingsLock.unlock()
        guard automaticLowLight, luminanceFrame % 15 == 0,
              let average = CIFilter(name: "CIAreaAverage", parameters: [
                kCIInputImageKey: image,
                kCIInputExtentKey: CIVector(cgRect: extent)
              ])?.outputImage else {
            if !automaticLowLight { smoothedExposureEV *= 0.88 }
            return
        }

        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            context.render(
                average,
                toBitmap: baseAddress,
                rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8,
                colorSpace: colorSpace
            )
        }
        let luminance = (0.2126 * Float(rgba[0]) +
                         0.7152 * Float(rgba[1]) +
                         0.0722 * Float(rgba[2])) / 255
        let lowLightWeight = 1 - smoothstep(0.06, 0.22, luminance)
        let targetEV = min(1.25, max(0, (0.22 - luminance) * 5.2)) * lowLightWeight
        smoothedExposureEV += (targetEV - smoothedExposureEV) * 0.18
    }

    private func applyTemporalDenoise(_ image: CIImage, amount: Float) -> CIImage {
        guard let previousDenoisedFrame else { return image }
        let difference = image.applyingFilter("CIDifferenceBlendMode", parameters: [
            kCIInputBackgroundImageKey: previousDenoisedFrame
        ])
        let stableAreaMask = difference.applyingFilter("CIColorInvert")
            .applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 3,
                kCIInputBrightnessKey: -0.55
            ])
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: previousDenoisedFrame,
            kCIInputMaskImageKey: stableAreaMask.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(amount), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(amount), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(amount), w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount)),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
            ])
        ])
    }

    private func applyBlackAndWhitePoints(_ image: CIImage, whites: Float, blacks: Float) -> CIImage {
        let scale = 1 + whites * 0.18 - blacks * 0.18
        let offset = blacks * 0.08 - whites * 0.08
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(scale), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(scale), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(scale), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(
                x: CGFloat(offset), y: CGFloat(offset), z: CGFloat(offset), w: 0
            )
        ])
    }

    private func applyChromaticAberration(_ image: CIImage, amount: Float, extent: CGRect) -> CIImage {
        func channel(_ vector: CIVector, offset: CGAffineTransform) -> CIImage {
            let shifted = image.transformed(by: offset).cropped(to: extent)
            return shifted.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": vector.x == 1
                    ? CIVector(x: 1, y: 0, z: 0, w: 0) : CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": vector.y == 1
                    ? CIVector(x: 0, y: 1, z: 0, w: 0) : CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": vector.z == 1
                    ? CIVector(x: 0, y: 0, z: 1, w: 0) : CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0)
            ])
        }
        let shift = CGFloat(amount) * CGFloat(min(width, height))
        let red = channel(CIVector(x: 1, y: 0, z: 0), offset: CGAffineTransform(translationX: shift, y: 0))
        let green = channel(CIVector(x: 0, y: 1, z: 0), offset: .identity)
        let blue = channel(CIVector(x: 0, y: 0, z: 1), offset: CGAffineTransform(translationX: -shift, y: 0))
        return red.applyingFilter("CIAdditionCompositing", parameters: [
            kCIInputBackgroundImageKey: green.applyingFilter("CIAdditionCompositing", parameters: [
                kCIInputBackgroundImageKey: blue
            ])
        ]).cropped(to: extent)
    }

    private func applyFilmGrain(_ image: CIImage, amount: Float, extent: CGRect) -> CIImage {
        randomOffset = (randomOffset + 17).truncatingRemainder(dividingBy: CGFloat(width))
        let noise = (CIFilter(name: "CIRandomGenerator")?.outputImage ?? image)
            .transformed(by: CGAffineTransform(translationX: randomOffset, y: randomOffset))
            .cropped(to: extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(amount) * 0.035, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(amount) * 0.035, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(amount) * 0.035, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -0.0175 * CGFloat(amount),
                                            y: -0.0175 * CGFloat(amount),
                                            z: -0.0175 * CGFloat(amount), w: 0)
            ])
        return noise.applyingFilter("CIAdditionCompositing", parameters: [
            kCIInputBackgroundImageKey: image
        ]).cropped(to: extent)
    }

    private func smoothstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        let x = min(1, max(0, (value - edge0) / (edge1 - edge0)))
        return x * x * (3 - 2 * x)
    }
}
