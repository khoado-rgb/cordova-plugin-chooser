# Chooser

## Overview

File chooser plugin for Cordova.

Install with Cordova CLI:

	$ cordova plugin add <git URL of this repo>

Supported Platforms:

* Android

* iOS

## API

	/**
	 * Displays native prompt for user to select a file (getFile) or
	 * one or more files (getFiles).
	 *
	 * @param accept Optional comma-separated MIME type filter
	 * (e.g. 'image/gif,video/*'). Defaults to all files.
	 *
	 * @returns Promise containing an array of the selected files' metadata.
	 * The plugin does not read file contents; use `uri` to read or upload the file.
	 *
	 * If user cancels, promise will be resolved as undefined.
	 * If error occurs, promise will be rejected with an error string.
	 */
	chooser.getFile(accept?: string) : Promise<undefined|Array<{
		mimeType: string;
		name: string;
		uri: string;
	}>>

	chooser.getFiles(accept?: string) : Promise<undefined|Array<{
		mimeType: string;
		name: string;
		uri: string;
	}>>

Both functions also accept optional `successCallback` and `failureCallback`
arguments after `accept`.

`getFile` resolves with an array containing a single file.

### Errors

* `OPERATION_IN_PROGRESS` — a picker opened by an earlier call is still showing.
  Only one call can be active at a time.
* `INVALID_ACCEPT` — `accept` was given but contains no usable MIME type.

### `accept` handling

Tokens are trimmed, lowercased and deduplicated; malformed tokens are ignored.
`*/*` anywhere in the list allows all files.

On iOS, each MIME type is mapped to a UTI. Supported wildcards are `application/*`,
`audio/*`, `font/*`, `image/*`, `text/*` and `video/*` (mapped to `public.movie`, which
covers .mp4/.mov). MIME types iOS does not recognise are ignored; if none remain, the call
fails with `INVALID_ACCEPT`.

## Compatibility

No runtime permissions or Info.plist usage descriptions are required.

**iOS 11+.** On iOS 14 and later the plugin uses `UTType` and
`UIDocumentPickerViewController(forOpeningContentTypes:asCopy:)`; on iOS 11–13 it falls
back to the legacy UTI functions and `init(documentTypes:in:)`. `UniformTypeIdentifiers`
is weak-linked, so apps with a deployment target below 14 still launch on older devices.
Swiping the picker away (iOS 13+) resolves the promise as canceled.

**Android API 19+.** Every API used is available since API 19 or earlier, so there are no
version-specific code paths. With a single MIME type the plugin sets it as the intent type,
which OEM file managers respect more reliably than `EXTRA_MIME_TYPES`.
If the OS kills the app while the picker is open, the result is delivered as
`event.pendingResult` on the `resume` event instead of the original promise:

	document.addEventListener('resume', function (event) {
		if (event.pendingResult && event.pendingResult.pluginServiceName === 'LowcodeChooser') {
			// event.pendingResult.pluginStatus === 'OK' → event.pendingResult.result
			// is the same JSON string (or 'RESULT_CANCELED') the promise would get.
		}
	});

## Example Usage

	(async () => {
		const files = await chooser.getFile('application/pdf,image/*');
		console.log(files ? files[0].name : 'canceled');
	})();

## Security and Lifetime Notes

* **`name` and `mimeType` are hints, not validated facts.** They come from the content
  provider (Android) or the file extension (iOS). Path separators and control characters
  are stripped from `name`, but the upload server must still validate the file type and
  contents itself. The `accept` filter is a UX hint, not a security boundary.
* **Consume `uri` right after selection; do not store it.** On Android the `content://`
  URI carries a temporary read grant that ends with the app's activity. On iOS the file
  is copied into the app's temporary `Inbox` directory, which the OS may clear, and large
  files take up that much disk space until then — delete the copy after uploading if needed.
* **Treat `uri` as sensitive.** Avoid logging it or sending it anywhere but your upload code.
