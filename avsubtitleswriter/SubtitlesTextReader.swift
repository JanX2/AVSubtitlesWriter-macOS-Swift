/*
 File: SubtitlesTextReader.swift
 Ported to Swift and bug fixes by Jan Weiß
 Abstract: A class for reading subtitles text, in the form of an String. It will turn the text into `CMSampleBuffer`s, and extract language code, extended language tag, and other metadata. See subtitles_text_en-US.txt for an example of the subtitles file format this class expects.
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


class SubtitlesTextReader {
	private var index = 0
	private var subtitles: [Subtitle] = []
	private var wantsSDH = false
	var languageCode: String = ""
	var extendedLanguageTag: String = ""
	
	init(text: String) {
		let textNS = text as NSString
		let textRange = NSRange(location: 0, length: textNS.length)

		let subtitlesExpression: NSRegularExpression
		
		do {
			// Check for a language.
			let languageExpression = try NSRegularExpression(pattern: "language: (.*)", options: [])
			if let languageResult = languageExpression.firstMatch(in: text, options: [], range: textRange) {
				languageCode = textNS.substring(with: languageResult.range(at: 1))
			}
			
			// Check for an extended language.
			let extendedLanguageExpression = try NSRegularExpression(pattern: "extended language: (.*)", options: [])
			if let extendedLanguageResult = extendedLanguageExpression.firstMatch(in: text, options: [], range: textRange) {
				extendedLanguageTag = textNS.substring(with: extendedLanguageResult.range(at: 1))
			}
			
			// See if SDH has been requested.
			let characteristicsExpression = try NSRegularExpression(pattern: "characteristics:.*(SDH)", options: .caseInsensitive)
			if let characteristicsResult = characteristicsExpression.firstMatch(in: text, options: [], range: textRange) {
				wantsSDH = (textNS.substring(with: characteristicsResult.range(at: 1)).caseInsensitiveCompare("SDH") == .orderedSame) ? true : false
			}
			
			subtitlesExpression = try NSRegularExpression(pattern: "(..):(..):(..),(...) --> (..):(..):(..),(...)( !!!)?\n(.*)", options: [])
		}
		catch {
			print("Regular expression error: \(error)")
			return
		}
		
		// Find the subtitle time ranges and text.
		//var forcedCount = 0
		subtitlesExpression.enumerateMatches(in: text, options: [], range: textRange) { (result, _, _) in
			if let result = result {
				// Get the text.
				let subtitleText = textNS.substring(with: result.range(at: 10))
				
				// Create the time range.
				let startTime =
				(Double(textNS.substring(with: result.range(at: 1)))! * 60.0 * 60.0) +
				(Double(textNS.substring(with: result.range(at: 2)))! * 60.0) +
				Double(textNS.substring(with: result.range(at: 3)))! +
				(Double(textNS.substring(with: result.range(at: 4)))! / 1000.0)
				
				let endTime =
				(Double(textNS.substring(with: result.range(at: 5)))! * 60.0 * 60.0) +
				(Double(textNS.substring(with: result.range(at: 6)))! * 60.0) +
				Double(textNS.substring(with: result.range(at: 7)))! +
				(Double(textNS.substring(with: result.range(at: 8)))! / 1000.0)
				
				let timeRange = CMTimeRange(start: CMTime(seconds: startTime, preferredTimescale: 600),
											duration: CMTime(seconds: endTime - startTime, preferredTimescale: 600))
				
				// Is it forced?
				var forced = false
				if result.range(at: 9).length > 0 &&
					textNS.substring(with: result.range(at: 9)) == " !!!" {
					forced = true
					//forcedCount += 1
				}
				
				// Stash a Subtitle object for later use by `copyNextSampleBuffer()`
				let subtitle: Subtitle = Subtitle(text: subtitleText,
												  timeRange: timeRange,
												  forced: forced)
				subtitles.append(subtitle)
			}
		}
	}
	
	static func subtitlesTextReaderWithText(text: String) -> SubtitlesTextReader {
		return SubtitlesTextReader(text: text)
	}
	
	func copyFormatDescription() -> CMFormatDescription? {
		// Take the format description from the first object. They are all the same since the display flag are all the same.
		return subtitles.first?.copyFormatDescription()
	}
	
	var metadata: [AVMetadataItem] {
		var metadata: [AVMetadataItem] = []
		
		// All subtitles must have the `AVMediaCharacteristic.transcribesSpokenDialogForAccessibility` characteristic.
		let spokenItem = AVMutableMetadataItem()
		spokenItem.key = AVMetadataKey.quickTimeUserDataKeyTaggedCharacteristic as (NSCopying & NSObjectProtocol)?
		spokenItem.keySpace = AVMetadataKeySpace.quickTimeUserData
		spokenItem.value = AVMediaCharacteristic.transcribesSpokenDialogForAccessibility.rawValue as NSCopying & NSObjectProtocol
		metadata.append(spokenItem)
		
		if wantsSDH {
			// SDH subtitles must also have the `AVMetadataKey.quickTimeUserDataKeyTaggedCharacteristic characteristic.
			let describesItem = AVMutableMetadataItem()
			describesItem.key = AVMetadataKey.quickTimeUserDataKeyTaggedCharacteristic as (NSCopying & NSObjectProtocol)?
			describesItem.keySpace = AVMetadataKeySpace.quickTimeUserData
			describesItem.value = AVMediaCharacteristic.describesMusicAndSoundForAccessibility.rawValue as NSCopying & NSObjectProtocol
			metadata.append(describesItem)
		}
		
		return metadata
	}
	
	func copyNextSampleBuffer() -> CMSampleBuffer? {
		guard index < subtitles.count else {
			return nil
		}
		
		let sampleBuffer = subtitles[index].copySampleBuffer()
		index += 1
		
		return sampleBuffer
	}
}
