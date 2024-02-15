/*
 File: main.swift
 Ported to Swift and bug fixes by Jan Weiß
 Abstract: This implementation file covers writing out subtitles to a new movie file. This is accomplished with AVAssetReader, AVAssetWriter, and the SubtitlesTextReader. Steps are taken to preserve much of the source movies tracks and metadata in the new movie it writes out.
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
 
 */

import Foundation
import AVFoundation

fileprivate func deleteExistingFile(_ fileURL: URL) {
	do {
		// Check if the output file exists.
		let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
		if let isRegularFile = resourceValues.isRegularFile, isRegularFile {
			try FileManager.default.removeItem(at: fileURL)
			print("Existing file deleted successfully.")
		}
	}
	catch let error as NSError {
		if error.code != NSFileReadNoSuchFileError &&
			error.code != NSFileNoSuchFileError {
			print(error)
		}
	}
	catch {
		print(error)
	}
}

func writeSubtitles(inputPath: String, outputPath: String, subtitlesTextPaths: [String]) {
	// Setup the asset reader and writer.
	let asset = AVAsset(url: URL(fileURLWithPath: inputPath))
	
	let assetReader: AVAssetReader
	do {
		assetReader = try AVAssetReader(asset: asset)
	}
	catch let error {
		print("Error creating AVAssetReader. Exiting: \(error)")
		return
	}
	
	let outputURL = URL(fileURLWithPath: outputPath)
	deleteExistingFile(outputURL)
	
	var assetWriter: AVAssetWriter
	do {
		assetWriter = try AVAssetWriter(url: outputURL, fileType: /*.mp4*/.mov)
	}
	catch {
		print("Error creating asset writer. Exiting: \(error)")
		return
	}
	
	// Copy metadata from the asset to the asset writer.
	var assetMetadata = [AVMetadataItem]()
	for metadataFormat in asset.availableMetadataFormats {
		assetMetadata += asset.metadata(forFormat: metadataFormat)
	}
	assetWriter.metadata = assetMetadata
	assetWriter.shouldOptimizeForNetworkUse = true
	
	struct InputOutputPair {
		let input: AVAssetWriterInput
		let output: AVAssetReaderTrackOutput
	}
	
	// Build up inputs and outputs for the reader and writer to carry over the tracks from the input movie into the new movie.
	var assetWriterInputsCorrespondingToOriginalTrackIDs = [CMPersistentTrackID: AVAssetWriterInput]()
	var inputsOutputs = [InputOutputPair]()
	for track in asset.tracks {
		let mediaType = track.mediaType
		
		// Make the reader.
		let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
		assetReader.add(trackOutput)
		
		// Make the writer input, using a source format hint if a format description is available.
		var input: AVAssetWriterInput
		let formatDescriptions = track.formatDescriptions as! [CMFormatDescription]
		if let formatDescription = formatDescriptions.first {
			input = AVAssetWriterInput(mediaType: mediaType,
									   outputSettings: nil,
									   sourceFormatHint: formatDescription)
			
			if mediaType == .video {
				input.transform = track.preferredTransform
			}
		}
		else {
			print("Skipping track on the assumption that there is no media data to carry over")
			continue
		}
		
		// Carry over language code.
		input.languageCode = track.languageCode
		input.extendedLanguageTag = track.extendedLanguageTag
		
		// Copy metadata from the asset track to the asset writer input.
		var trackMetadata = [AVMetadataItem]()
		for metadataFormat in track.availableMetadataFormats {
			trackMetadata += track.metadata(forFormat: metadataFormat)
		}
		input.metadata = trackMetadata
		
		// Add the input, if that's okay to do.
		if assetWriter.canAdd(input) {
			assetWriter.add(input)
			
			// Store the input and output to be used later when actually writing out the new movie.
			inputsOutputs.append(InputOutputPair(input: input,
												 output: trackOutput))
			// Track inputs corresponsing to track IDs for later preservation of track groups.
			assetWriterInputsCorrespondingToOriginalTrackIDs[track.trackID] = input
		}
		else {
			print("Skipping input because it cannot be added to the asset writer.")
		}
	}
	
	// Setup the inputs and outputs for new subtitle tracks.
	var newSubtitlesInputs = [AVAssetWriterInput]()
	var subtitlesInputsOutputs = [[String: Any]]()
	for subtitlesPath in subtitlesTextPaths {
		// Read the contents of the subtitles file
		guard let text = try? String(contentsOf: URL(fileURLWithPath: subtitlesPath), encoding: .utf8) else {
			print("There was a problem reading a subtitles file")
			continue
		}
		
		// Make the subtitles reader.
		let subtitlesTextReader = SubtitlesTextReader(text: text)
		
		// Make the writer input, using a source format hint if a format description is available.
		guard let formatDescription = subtitlesTextReader.copyFormatDescription()
		else {
			print("Skipping subtitles reader on the assumption that there is no media data to carry over")
			continue
		}
		
		let subtitlesInput = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: formatDescription)

		subtitlesInput.languageCode = subtitlesTextReader.languageCode
		subtitlesInput.extendedLanguageTag = subtitlesTextReader.extendedLanguageTag
		subtitlesInput.metadata = subtitlesTextReader.metadata
		
		if assetWriter.canAdd(subtitlesInput) {
			assetWriter.add(subtitlesInput)
			
			// Store the input and output to be used later when actually writing out the new movie.
			subtitlesInputsOutputs.append(["input": subtitlesInput, "output": subtitlesTextReader])
			newSubtitlesInputs.append(subtitlesInput)
		}
		else {
			print("Skipping subtitles input because it cannot be added to the asset writer")
		}
	}
	
	// Preserve track groups from the original asset.
	var groupedSubtitles = false
	for trackGroup in asset.trackGroups {
		// Collect the inputs that correspond to the group's track IDs in an array.
		var inputs = [AVAssetWriterInput]()
		var defaultInput: AVAssetWriterInput?
		for trackIDNumber in trackGroup.trackIDs {
			let trackID = CMPersistentTrackID(trackIDNumber.int32Value)
			guard let input = assetWriterInputsCorrespondingToOriginalTrackIDs[trackID] else {
				continue
			}
			
			inputs.append(input)
			
			// Determine which of the inputs is the default according to the enabled state of the corresponding tracks.
			if defaultInput == nil,
			   let track = asset.track(withTrackID: trackID),
			   track.isEnabled {
				defaultInput = input
			}
		}
		
		// See if this is a legible group (all of the tracks have characteristic `AVMediaCharacteristic.legible`), and group the new subtitle tracks with it if so.
		var isLegibleGroup = true
		for trackIDNumber in trackGroup.trackIDs {
			let trackID = CMPersistentTrackID(trackIDNumber.int32Value)
			if let track = asset.track(withTrackID: trackID),
			   !track.hasMediaCharacteristic(AVMediaCharacteristic.legible) {
				isLegibleGroup = false
				break
			}
		}
		
		// If it is a legible group, add the new subtitles to this group
		if !groupedSubtitles && isLegibleGroup {
			inputs += newSubtitlesInputs
			groupedSubtitles = true
		}
		
		let inputGroup = AVAssetWriterInputGroup(inputs: inputs, defaultInput: defaultInput)
		if assetWriter.canAdd(inputGroup) {
			assetWriter.add(inputGroup)
		}
		else {
			print("Cannot add asset writer group")
		}
	}
	
	// If no legible group was found to add the new subtitles to, create a group for them (if there are any).
	if !groupedSubtitles && !newSubtitlesInputs.isEmpty {
		let inputGroup = AVAssetWriterInputGroup(inputs: newSubtitlesInputs, defaultInput: nil)
		if assetWriter.canAdd(inputGroup) {
			assetWriter.add(inputGroup)
		}
		else {
			print("Cannot add asset writer group")
		}
	}
	
	// Preserve track references from original asset.
	var trackReferencesCorrespondingToOriginalTrackIDs = [CMPersistentTrackID: [AVAssetTrack.AssociationType: [CMPersistentTrackID]]]()
	for track in asset.tracks {
		var trackReferencesForTrack = [AVAssetTrack.AssociationType: [CMPersistentTrackID]]()
		let availableTrackAssociationTypes = Set(track.availableTrackAssociationTypes)
		for trackAssociationType in availableTrackAssociationTypes {
			let associatedTracks = track.associatedTracks(ofType: trackAssociationType)
			if associatedTracks.count > 0 {
				var associatedTrackIDs = [CMPersistentTrackID]()
				for associatedTrack in associatedTracks {
					associatedTrackIDs.append(associatedTrack.trackID)
				}
				trackReferencesForTrack[trackAssociationType] = associatedTrackIDs
			}
		}
		
		trackReferencesCorrespondingToOriginalTrackIDs[track.trackID] = trackReferencesForTrack
	}
	
	for (referencingTrackIDKey, trackReferences) in trackReferencesCorrespondingToOriginalTrackIDs {
		if let referencingInput = assetWriterInputsCorrespondingToOriginalTrackIDs[referencingTrackIDKey] {
			for (trackReferenceTypeKey, referencedTrackIDs) in trackReferences {
				for thisReferencedTrackID in referencedTrackIDs {
					if let referencedInput = assetWriterInputsCorrespondingToOriginalTrackIDs[thisReferencedTrackID],
					   referencingInput.canAddTrackAssociation(withTrackOf: referencedInput,
															   type: trackReferenceTypeKey.rawValue) {
						referencingInput.addTrackAssociation(withTrackOf: referencedInput,
															 type: trackReferenceTypeKey.rawValue)
					}
				}
			}
		}
	}
	
	// Write the movie.
	guard assetWriter.startWriting() else {
		print("Asset writer failed to start writing: \(String(describing: assetWriter.error))")
		return
	}
	assetWriter.startSession(atSourceTime: .zero)
	
	let dispatchGroup = DispatchGroup()
	
	assetReader.startReading()
	
	// Write samples from AVAssetReaderTrackOutputs.
	for inputOutput in inputsOutputs {
		dispatchGroup.enter()
		let requestMediaDataQueue = DispatchQueue(label: "request media data")
		
		let input = inputOutput.input
		let assetReaderTrackOutput = inputOutput.output
		
		input.requestMediaDataWhenReady(on: requestMediaDataQueue) {
			while input.isReadyForMoreMediaData {
				if let nextSampleBuffer = assetReaderTrackOutput.copyNextSampleBuffer() {
					input.append(nextSampleBuffer)
				}
				else {
					input.markAsFinished()
					dispatchGroup.leave()
					
					if assetReader.status == .failed {
						print("The reader failed: \(String(describing: assetReader.error))")
					}
					
					break
				}
			}
		}
	}
	
	// Write samples from SubtitlesTextReaders.
	for subtitlesInputOutput in subtitlesInputsOutputs {
		dispatchGroup.enter()
		let requestMediaDataQueue = DispatchQueue(label: "request media data")
		if let input = subtitlesInputOutput["input"] as? AVAssetWriterInput, let subtitlesTextReader = subtitlesInputOutput["output"] as? SubtitlesTextReader {
			input.requestMediaDataWhenReady(on: requestMediaDataQueue) {
				while input.isReadyForMoreMediaData {
					if let nextSampleBuffer = subtitlesTextReader.copyNextSampleBuffer() {
						input.append(nextSampleBuffer)
					}
					else {
						input.markAsFinished()
						dispatchGroup.leave()
						
						break
					}
				}
			}
		}
	}
	
	dispatchGroup.wait()
	assetReader.cancelReading()
	
	dispatchGroup.enter()
	assetWriter.finishWriting {
		if assetWriter.status == .completed {
			print("Writer succeeded: \(assetWriter.outputURL)")
		} else if assetWriter.status == .failed {
			print("Writer failed with error: \(String(describing: assetWriter.error))")
		}
		dispatchGroup.leave()
	}
	dispatchGroup.wait()
}

func main() {
	let arguments = CommandLine.arguments
	
	var inputPath: String?
	var outputPath: String?
	var subtitlesTextPaths = [String]()
	
	var index = 1
	while index < arguments.count {
		let arg = arguments[index]
		switch arg {
		case "-i", "--input":
			if index + 1 < arguments.count {
				inputPath = arguments[index + 1]
				index += 1
			}
		case "-o", "--output":
			if index + 1 < arguments.count {
				outputPath = arguments[index + 1]
				index += 1
			}
		case "-s", "--subtitles":
			if index + 1 < arguments.count {
				subtitlesTextPaths.append(arguments[index + 1])
				index += 1
			}
		default:
			break
		}
		index += 1
	}
	
	if let inputPath = inputPath, let outputPath = outputPath {
		writeSubtitles(inputPath: inputPath,
					   outputPath: outputPath,
					   subtitlesTextPaths: subtitlesTextPaths)
	}
	else {
		print("Usage: subtitleswriter -i [input_file] -o [output_file] -s [subtitles_file]")
		print("Creates a new movie file at the specified output location, with audio, video, and subtitles from the input source, adding subtitles from the provide subtitles file(s). Each subtitles file will become a subtitle track in the output movie.")
	}
}

main()
