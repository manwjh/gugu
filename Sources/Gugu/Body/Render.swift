import AppKit
import SpriteKit

/// Offscreen render of the bird in a given pose to a PNG — no screen-capture
/// permission needed. Used to visually verify the procedural artwork.
@MainActor
func runRender(pose: String, to path: String) {
    let size = CGSize(width: 150, height: 150)
    let scene = SKScene(size: size)
    scene.backgroundColor = NSColor(calibratedWhite: 0.92, alpha: 1) // light gray bg for visibility
    let bird = BirdNode()
    bird.position = CGPoint(x: size.width / 2, y: 20)
    scene.addChild(bird)

    // apply a static pose
    switch pose {
    case "front":
        bird.setViewDirection(.front, animated: false)
    case "back":
        bird.setViewDirection(.back, animated: false)
    case "side":
        bird.setViewDirection(.side, animated: false)
    case "sleep":
        bird.setViewDirection(.front, animated: false)
        bird.eyelidL.yScale = 1.0
        bird.eyelidR.yScale = 1.0
        bird.zzz.alpha = 0.9
        bird.yScale = 0.92
    case "blink":
        bird.setViewDirection(.front, animated: false)
        bird.eyelidL.yScale = 1.0
        bird.eyelidR.yScale = 1.0
    case "happy":
        bird.setViewDirection(.front, animated: false)
        for b in [bird.blushL, bird.blushR] { b.alpha = 1 }
        bird.head.zRotation = 0.2
    case "wing":
        bird.setViewDirection(.front, animated: false)
        bird.wingL.zRotation = 0.9
        bird.wingR.zRotation = 0.9
    case "tilt":
        bird.setViewDirection(.front, animated: false)
        bird.head.zRotation = 0.22
    default:
        bird.setViewDirection(.front, animated: false)
    }

    if pose == "manpu" { bird.debugPlaceAllManpu() }   // TEMP-DEBUG


    let view = SKView(frame: CGRect(origin: .zero, size: size))
    view.allowsTransparency = false
    view.presentScene(scene)
    view.layoutSubtreeIfNeeded()

    guard let texture = view.texture(from: scene) else {
        print("render failed: no texture")
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: texture.cgImage())
    guard let data = rep.representation(using: .png, properties: [:]) else {
        print("render failed: no png data")
        exit(1)
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("rendered \(pose) → \(path)")
    } catch {
        print("write failed: \(error)")
        exit(1)
    }
    exit(0)
}
