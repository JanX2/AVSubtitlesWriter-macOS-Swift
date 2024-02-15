/*
 File: Subtitle.swift
 Ported to Swift and bug fixes by Jan Weiß
 Abstract: A data class for storing a single section of subtitles text.
 Version: 1.0.2
 
 Disclaimer: IMPORTANT:  This Apple software is supplied to you by Apple
 Inc. ("Apple") in consideration of your agreement to the following
 terms, and your use, installation, modification or redistribution of
 this Apple software constitutes acceptance of these terms.  If you do
 not agree with these terms, please do not use, install, modify or
 redistribute this Apple software.
 
 In consideration of your agreement to abide by the following terms, and
 subject to these terms, Apple grants you a personal, non-exclusive
 license, under Apple's copyrights in this original Apple software (the
 "Apple Software"), to use, reproduce, modify and redistribute the Apple
 Software, with or without modifications, in source and/or binary forms;
 provided that if you redistribute the Apple Software in its entirety and
 without modifications, you must retain this notice and the following
 text and disclaimers in all such redistributions of the Apple Software.
 Neither the name, trademarks, service marks or logos of Apple Inc. may
 be used to endorse or promote products derived from the Apple Software
 without specific prior written permission from Apple.  Except as
 expressly stated in this notice, no other rights or licenses, express or
 implied, are granted by Apple herein, including but not limited to any
 patent rights that may be infringed by your derivative works or by other
 works in which the Apple Software may be incorporated.
 
 The Apple Software is provided by Apple on an "AS IS" basis.  APPLE
 MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
 THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS
 FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND
 OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS.
 
 IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL
 OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION,
 MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED
 AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE),
 STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE
 POSSIBILITY OF SUCH DAMAGE.
 
 Copyright (C) 2013 Apple Inc. All Rights Reserved.
 Copyright (C) 2024 Jan Weiß. All Rights Reserved.
 
 */

import Foundation
import AVFoundation


class Subtitle {
	var text: String
	var timeRange: CMTimeRange
	var forced: Bool
	var displayFlags: CMTextDisplayFlags = 0
	
	init(text: String,
		 timeRange: CMTimeRange,
		 forced: Bool,
		 displayFlags: CMTextDisplayFlags = 0) {
		self.text = text
		self.timeRange = timeRange
		self.forced = forced
		self.displayFlags = displayFlags
	}
	
	func copyFormatDescription() -> CMFormatDescription? {
		let extensions: [AnyHashable: Any] =
		[kCMTextFormatDescriptionExtension_DisplayFlags: NSNumber(value: displayFlags),
	  kCMTextFormatDescriptionExtension_BackgroundColor: [kCMTextFormatDescriptionColor_Red: 0,
														kCMTextFormatDescriptionColor_Green: 0,
														 kCMTextFormatDescriptionColor_Blue: 0,
														kCMTextFormatDescriptionColor_Alpha: 255],
	   kCMTextFormatDescriptionExtension_DefaultTextBox: [kCMTextFormatDescriptionRect_Top: 0,
														 kCMTextFormatDescriptionRect_Left: 0,
													   kCMTextFormatDescriptionRect_Bottom: 0,
														kCMTextFormatDescriptionRect_Right: 0],
		 kCMTextFormatDescriptionExtension_DefaultStyle: [kCMTextFormatDescriptionStyle_StartChar: 0,
															kCMTextFormatDescriptionStyle_EndChar: 0,
															   kCMTextFormatDescriptionStyle_Font: 1,
														   kCMTextFormatDescriptionStyle_FontFace: 0,
													kCMTextFormatDescriptionStyle_ForegroundColor:
															[kCMTextFormatDescriptionColor_Red: 255,
														   kCMTextFormatDescriptionColor_Green: 255,
															kCMTextFormatDescriptionColor_Blue: 255,
														   kCMTextFormatDescriptionColor_Alpha: 255],
														   kCMTextFormatDescriptionStyle_FontSize: 255],
kCMTextFormatDescriptionExtension_HorizontalJustification: 0,
kCMTextFormatDescriptionExtension_VerticalJustification: 0,
			kCMTextFormatDescriptionExtension_FontTable: ["1": "Sans-Serif"]]
		
		var formatDescription: CMFormatDescription?
		CMFormatDescriptionCreate(allocator: nil,
								  mediaType: kCMMediaType_Subtitle,
								  mediaSubType: kCMTextFormatType_3GText,
								  extensions: extensions as CFDictionary,
								  formatDescriptionOut: &formatDescription)
		
		return formatDescription
	}
	
	fileprivate func byteWiseStore<T: FixedWidthInteger>(_ value: T,
								   to ptr: UnsafeMutablePointer<UInt8>) {
		let valuePointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
		valuePointer.pointee = value
		
		let rawPtr = UnsafeMutableRawPointer(ptr)
		rawPtr.copyMemory(from: UnsafeRawPointer(valuePointer),
						  byteCount: MemoryLayout<T>.size)
	}
	
	func copySampleBuffer() -> CMSampleBuffer? {
		let textData = text.data(using: .utf8)
		
		// Setup the sample size.
		var textLength: UInt16 = 0;
		var sampleSize = 0
		
		if let textData = textData {
			textLength = UInt16(textData.count) // Must not include C-string terminator in the length.
		}
		
		sampleSize = Int(textLength) + MemoryLayout<UInt16>.size
		
		if forced {
			sampleSize += (MemoryLayout<UInt32>.size * 2); // For the 'frcd' atom.
		}
		
		// Allocate space for the length of text, the text, and any extensions.
		// This variable should be UnsafeMutablePointer<UInt8> for byte alignment reasons.
		let samplePtr = UnsafeMutablePointer<UInt8>.allocate(capacity: sampleSize)
		samplePtr.initialize(repeating: UInt8(0), count: sampleSize)
		
		samplePtr.withMemoryRebound(to: UInt16.self, capacity: 1) { ptr in
			let textLengthBigEndian = textLength.bigEndian
			ptr.pointee = textLengthBigEndian
		}
		
		if textLength > 0,
		   let textData = textData {
			textData.copyBytes(to: samplePtr.advanced(by: MemoryLayout<UInt16>.size),
							   count: Int(textLength))
		}
		
		if forced {
			let ptr = samplePtr.advanced(by: MemoryLayout<UInt16>.size + Int(textLength))
			
			// Make room for the forced atom ('frcd').
			let forcedAtomSizeBigEndian = UInt32(MemoryLayout<UInt32>.size * 2).bigEndian
			let forcedAtomBigEndian = UInt32(bitPattern: Int32(0x66726364)).bigEndian // UInt32("frcd".osType()).bigEndian
			
			// The more convenient Swift `withMemoryRebound` doesn’t work reliably here,
			// because we may have to store the 32-bit values unaligned to the host’s pointer alignment for UInt32.
			// For example, the `CMSampleBuffer` may need to store the forced atom at an arbitrary,
			// non-UInt32-multiple offset relative to the initial `samplePtr` due to the text length.
			byteWiseStore(forcedAtomSizeBigEndian, to: ptr)
			byteWiseStore(forcedAtomBigEndian, to: ptr.advanced(by: MemoryLayout<UInt32>.size))
		}
		
		var dataBuffer: CMBlockBuffer?
		CMBlockBufferCreateWithMemoryBlock(allocator: nil,
										   memoryBlock: samplePtr,
										   blockLength: sampleSize,
										   blockAllocator: kCFAllocatorNull,
										   customBlockSource: nil,
										   offsetToData: 0,
										   dataLength: sampleSize,
										   flags: 0,
										   blockBufferOut: &dataBuffer)
		
		var sampleTiming = CMSampleTimingInfo(duration: timeRange.duration,
											  presentationTimeStamp: timeRange.start,
											  decodeTimeStamp: CMTime.invalid)
		
		guard let formatDescription = copyFormatDescription() else {
			return nil
		}
		
		var sampleBuffer: CMSampleBuffer?
		CMSampleBufferCreate(allocator: kCFAllocatorDefault,
							 dataBuffer: dataBuffer!,
							 dataReady: true,
							 makeDataReadyCallback: nil,
							 refcon: nil,
							 formatDescription: formatDescription,
							 sampleCount: 1,
							 sampleTimingEntryCount: 1,
							 sampleTimingArray: &sampleTiming,
							 sampleSizeEntryCount: 1,
							 sampleSizeArray: &sampleSize,
							 sampleBufferOut: &sampleBuffer)
		
		return sampleBuffer
	}
}


extension String {
	
	// Based on:
	// https://stackoverflow.com/a/51259436
	public func osType() -> OSType {
		var result: UInt = 0
		
		if let data = self.data(using: .macOSRoman),
			data.count == 4 {
			data.withUnsafeBytes {
				for i in 0..<data.count {
					result = result << 8 + UInt($0[i])
				}
			}
		}
		
		return OSType(result)
	}
	
}
