// Host-only visual check; never launches a simulator or device.
// swiftc -parse-as-library Tools/RenderNetworkLogoEdges.swift -o /tmp/oath-logo-edges
// /tmp/oath-logo-edges "$PWD" "$PWD/output/network-logo-edge-check" [--dark]
import AppKit
import SwiftUI
import CoreGraphics
import ImageIO

@main struct Preview {
 @MainActor static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1])
  let out=URL(fileURLWithPath:CommandLine.arguments[2])
  try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
  let names=["bitcoin","bnb","aptos","arbitrum","arc","avalanche","base","bitcoincash","dogecoin","ethereum","telos"]
  let width=1000,height=names.count*180+80
  let ctx=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  let dark = CommandLine.arguments.contains("--dark")
  ctx.setFillColor(CGColor(gray:dark ? 0.08 : 1,alpha:1)); ctx.fill(CGRect(x:0,y:0,width:width,height:height))
  let ns=NSGraphicsContext(cgContext:ctx,flipped:false)
  NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=ns
  func text(_ s:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat=18) {
   (s as NSString).draw(at:NSPoint(x:x,y:y),withAttributes:[.font:NSFont.systemFont(ofSize:size),.foregroundColor:dark ? NSColor.white : NSColor.black])
  }
  text("CHAIN",20,CGFloat(height-40));text("BEFORE · 38pt @3x",200,CGFloat(height-40));text("AFTER · 38pt @3x",440,CGFloat(height-40));text("AFTER · BADGE @3x",700,CGFloat(height-40))
  for (i,name) in names.enumerated() {
   let url=root.appendingPathComponent("OathApp/Assets.xcassets/Networks/network-\(name).imageset/logo.png")
   let image=NSImage(contentsOf:url)!
   let beforeImage = name == "telos" ? (NSImage(contentsOf:out.appendingPathComponent("telos-before.png")) ?? image) : image
   let before=ImageRenderer(content:Image(nsImage:beforeImage).renderingMode(.original).resizable().scaledToFit().frame(width:38,height:38).clipShape(Circle()))
   before.scale=3
   let after=ImageRenderer(content:Image(nsImage:image).renderingMode(.original).resizable().interpolation(.high).scaledToFit().frame(width:38,height:38))
   after.scale=3
   let badge=ImageRenderer(content:Image(nsImage:image).renderingMode(.original).resizable().interpolation(.high).scaledToFit().frame(width:15.2,height:15.2))
   badge.scale=3
   let y=CGFloat(height-70-(i+1)*180)
   text(name,20,y+60)
   ctx.interpolationQuality = .none
   ctx.draw(before.cgImage!,in:CGRect(x:220,y:y+20,width:114,height:114))
   ctx.draw(after.cgImage!,in:CGRect(x:460,y:y+20,width:114,height:114))
   ctx.draw(badge.cgImage!,in:CGRect(x:740,y:y+55,width:46,height:46))
   let dest=CGImageDestinationCreateWithURL(out.appendingPathComponent(name+"-after.png") as CFURL,"public.png" as CFString,1,nil)!
   CGImageDestinationAddImage(dest,after.cgImage!,nil); CGImageDestinationFinalize(dest)
  }
  NSGraphicsContext.restoreGraphicsState()
  let dest=CGImageDestinationCreateWithURL(out.appendingPathComponent(dark ? "comparison-dark.png" : "comparison.png") as CFURL,"public.png" as CFString,1,nil)!
  CGImageDestinationAddImage(dest,ctx.makeImage()!,nil);CGImageDestinationFinalize(dest)
 }
}
