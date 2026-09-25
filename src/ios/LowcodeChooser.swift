import UIKit
import MobileCoreServices
import UniformTypeIdentifiers
import Foundation


// Version split:
// - iOS 14+: UTType + UIDocumentPickerViewController(forOpeningContentTypes:asCopy:)
// - iOS 11-13: legacy UTI functions + UIDocumentPickerViewController(documentTypes:in:)
// UniformTypeIdentifiers is weak-linked (see plugin.xml) so the app still launches on iOS < 14.
@objc(LowcodeChooser)
class LowcodeChooser : CDVPlugin {
	var commandCallback: String?
	weak var picker: UIDocumentPickerViewController?

	static let wildcardUTIs: [String: String] = [
		"application/*": "public.data",
		"audio/*": "public.audio",
		"font/*": "public.font",
		"image/*": "public.image",
		"text/*": "public.text",
		// Not public.video: .mp4/.mov/.m4v only conform to public.movie.
		"video/*": "public.movie"
	]

	@objc(getFile:)
	func getFile (command: CDVInvokedUrlCommand) {
		self.getFilesInternal(command: command, allowMultiple: false)
	}

	@objc(getFiles:)
	func getFiles (command: CDVInvokedUrlCommand) {
		self.getFilesInternal(command: command, allowMultiple: true)
	}

	func getFilesInternal (command: CDVInvokedUrlCommand, allowMultiple: Bool) {
		if self.commandCallback != nil {
			if self.picker?.presentingViewController != nil {
				self.send("OPERATION_IN_PROGRESS", CDVCommandStatus_ERROR, to: command.callbackId)
				return
			}

			// The picker went away without notifying the delegate; release the stale call.
			self.send("RESULT_CANCELED")
		}

		let accept = (command.arguments.first as? String) ?? ""

		guard
			let utis = self.utis(forAccept: accept),
			let picker = self.makePicker(utis: utis)
		else {
			self.send("INVALID_ACCEPT", CDVCommandStatus_ERROR, to: command.callbackId)
			return
		}

		guard let presenter = self.topViewController() else {
			self.send("View controller unavailable.", CDVCommandStatus_ERROR, to: command.callbackId)
			return
		}

		picker.delegate = self
		if #available(iOS 11.0, *) {
			picker.allowsMultipleSelection = allowMultiple
		}
		if #available(iOS 13.0, *) {
			// Swipe-to-dismiss on iOS 13+ sheets is reported here.
			picker.presentationController?.delegate = self
		}

		self.commandCallback = command.callbackId
		self.picker = picker
		presenter.present(picker, animated: false, completion: nil)
	}

	/// Presenting from a view controller that is already presenting something fails silently,
	/// which would leave the promise pending forever.
	func topViewController () -> UIViewController? {
		guard var top = self.viewController, top.view.window != nil else {
			return nil
		}
		while let presented = top.presentedViewController, !presented.isBeingDismissed {
			top = presented
		}
		return top
	}

	/// Maps the comma-separated MIME filter to UTIs. Unsupported or malformed
	/// tokens are ignored; returns nil if tokens were given but none are supported.
	func utis (forAccept accept: String) -> [String]? {
		var utis: [String] = []
		var hasTokens = false

		for token in accept.components(separatedBy: ",") {
			let mimeType = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			if mimeType.isEmpty {
				continue
			}
			hasTokens = true

			if mimeType == "*/*" {
				return ["public.data"]
			}

			if let uti = self.uti(forMimeType: mimeType) {
				if !utis.contains(uti) {
					utis.append(uti)
				}
			}
			else {
				NSLog("%@", "FileChooserPlugin ignoring unsupported MIME type \(mimeType)")
			}
		}

		if !hasTokens {
			return ["public.data"]
		}

		if utis.contains("com.apple.iwork.pages.sffpages") {
			utis.append("com.apple.iwork.pages.pages")
		}

		if utis.contains("com.apple.iwork.numbers.sffnumbers") {
			utis.append("com.apple.iwork.numbers.numbers")
		}

		let logVar = utis.joined(separator: ",")
		NSLog("%@", "FileChooserPlugin \(logVar)")

		return utis.isEmpty ? nil : utis
	}

	func uti (forMimeType mimeType: String) -> String? {
		if let uti = LowcodeChooser.wildcardUTIs[mimeType] {
			return uti
		}

		if mimeType.contains("*") {
			return nil
		}

		if #available(iOS 14.0, *) {
			guard let type = UTType(mimeType: mimeType), !type.isDynamic else {
				return nil
			}
			return type.identifier
		}

		guard let utiUnmanaged = UTTypeCreatePreferredIdentifierForTag(
			kUTTagClassMIMEType,
			mimeType as CFString,
			nil
		) else {
			return nil
		}

		let uti = utiUnmanaged.takeRetainedValue() as String
		return uti.hasPrefix("dyn.") ? nil : uti
	}

	func makePicker (utis: [String]) -> UIDocumentPickerViewController? {
		if #available(iOS 14.0, *) {
			// UTIs the OS does not declare (e.g. iWork types without iWork installed) are dropped.
			let types = utis.compactMap { UTType($0) }
			if types.isEmpty {
				return nil
			}
			return UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
		}

		return UIDocumentPickerViewController(documentTypes: utis, in: .import)
	}

	override func onReset () {
		// The page that made the request is gone; close the picker and drop its callback.
		self.commandCallback = nil
		if let picker = self.picker, picker.presentingViewController != nil {
			picker.dismiss(animated: false, completion: nil)
		}
		self.picker = nil
	}

	func detectMimeType (_ url: URL) -> String {
		if #available(iOS 14.0, *) {
			return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
				?? "application/octet-stream"
		}

		if let uti = UTTypeCreatePreferredIdentifierForTag(
			kUTTagClassFilenameExtension,
			url.pathExtension as CFString,
			nil
		)?.takeRetainedValue() {
			if let mimetype = UTTypeCopyPreferredTagWithClass(
				uti,
				kUTTagClassMIMEType
			)?.takeRetainedValue() as? String {
				return mimetype
			}
		}

		return "application/octet-stream"
	}

	/// File names are untrusted input; never let them carry path separators or control characters.
	func sanitizeFileName (_ name: String) -> String {
		let unsafe = CharacterSet(charactersIn: "/\\").union(.controlCharacters)
		let sanitized = name
			.components(separatedBy: unsafe)
			.joined(separator: "_")
			.trimmingCharacters(in: .whitespaces)

		if sanitized.isEmpty || sanitized == "." || sanitized == ".." {
			return "File"
		}
		return sanitized
	}

	func documentWasSelected (urls: [URL]) {
		let result = urls.map { url -> [String: String] in
			return [
				"name": self.sanitizeFileName(url.lastPathComponent),
				"mimeType": self.detectMimeType(url),
				"uri": url.absoluteString
			]
		}

		do {
			let data = try JSONSerialization.data(withJSONObject: result, options: [])
			if let message = String(data: data, encoding: String.Encoding.utf8) {
				self.send(message)
			}
			else {
				self.sendError("Serializing result failed.")
			}
		}
		catch let error {
			self.sendError(error.localizedDescription)
		}
	}

	func send (_ message: String, _ status: CDVCommandStatus = CDVCommandStatus_OK) {
		if let callbackId = self.commandCallback {
			self.commandCallback = nil
			self.send(message, status, to: callbackId)
		}
	}

	func send (_ message: String, _ status: CDVCommandStatus, to callbackId: String) {
		let pluginResult = CDVPluginResult(
			status: status,
			messageAs: message
		)

		self.commandDelegate?.send(
			pluginResult,
			callbackId: callbackId
		)
	}

	func sendError (_ message: String) {
		self.send(message, CDVCommandStatus_ERROR)
	}
}

extension LowcodeChooser : UIDocumentPickerDelegate {
	@available(iOS 11.0, *)
	func documentPicker (
		_ controller: UIDocumentPickerViewController,
		didPickDocumentsAt urls: [URL]
	) {
		self.documentWasSelected(urls: urls)
	}

	func documentPicker (
		_ controller: UIDocumentPickerViewController,
		didPickDocumentAt url: URL
	) {
		let urls = [url]
		self.documentWasSelected(urls: urls)
	}

	func documentPickerWasCancelled (_ controller: UIDocumentPickerViewController) {
		self.send("RESULT_CANCELED")
	}
}

extension LowcodeChooser : UIAdaptivePresentationControllerDelegate {
	@available(iOS 13.0, *)
	func presentationControllerDidDismiss (_ presentationController: UIPresentationController) {
		self.send("RESULT_CANCELED")
	}
}
