package com.lowcode.outsystems.chooser;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.ContentResolver;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.provider.OpenableColumns;

import java.util.LinkedHashSet;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Pattern;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.PluginResult;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;


public class LowcodeChooser extends CordovaPlugin {
	private static final String ACTION_OPEN = "getFile";
	private static final String ACTION_OPEN_MANY = "getFiles";
	private static final String DEFAULT_NAME = "File";
	private static final Pattern MIME_TYPE =
		Pattern.compile("^[a-z0-9][a-z0-9!#$&^_.+-]*/([a-z0-9][a-z0-9!#$&^_.+-]*|\\*)$");
	private static final int PICK_FILE_REQUEST = 1;
	private CallbackContext callback;

	@Override
	public boolean execute (String action, JSONArray args, CallbackContext callbackContext) {
		boolean allowMultiple;
		if (action.equals(LowcodeChooser.ACTION_OPEN)) {
			allowMultiple = false;
		} else if (action.equals(LowcodeChooser.ACTION_OPEN_MANY)) {
			allowMultiple = true;
		} else {
			return false;
		}

		if (this.callback != null) {
			callbackContext.error("OPERATION_IN_PROGRESS");
			return true;
		}

		Object accept = args.opt(0);
		String[] mimeTypes;
		try {
			mimeTypes = LowcodeChooser.parseAccept(accept instanceof String ? (String) accept : "");
		}
		catch (IllegalArgumentException err) {
			callbackContext.error("INVALID_ACCEPT");
			return true;
		}

		this.chooseFile(callbackContext, mimeTypes, allowMultiple);
		return true;
	}

	/**
	 * Normalizes the comma-separated MIME filter. Returns null when every type is allowed.
	 * Malformed tokens are ignored; throws if tokens were given but none are valid.
	 */
	private static String[] parseAccept (String accept) {
		Set<String> mimeTypes = new LinkedHashSet<String>();
		boolean hasTokens = false;

		for (String token : accept.split(",")) {
			String mimeType = token.trim().toLowerCase(Locale.ROOT);
			if (mimeType.isEmpty()) {
				continue;
			}
			hasTokens = true;
			if (mimeType.equals("*/*")) {
				return null;
			}
			if (LowcodeChooser.MIME_TYPE.matcher(mimeType).matches()) {
				mimeTypes.add(mimeType);
			}
		}

		if (!hasTokens) {
			return null;
		}
		if (mimeTypes.isEmpty()) {
			throw new IllegalArgumentException("No valid MIME types in accept.");
		}
		return mimeTypes.toArray(new String[0]);
	}

	private void chooseFile (CallbackContext callbackContext, String[] mimeTypes, boolean allowMultiple) {
		Intent intent = new Intent(Intent.ACTION_GET_CONTENT);
		if (mimeTypes != null && mimeTypes.length == 1) {
			// Many OEM file managers ignore EXTRA_MIME_TYPES but do honour the intent type.
			intent.setType(mimeTypes[0]);
		} else {
			intent.setType("*/*");
			if (mimeTypes != null) {
				intent.putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes);
			}
		}
		intent.addCategory(Intent.CATEGORY_OPENABLE);
		intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, allowMultiple);
		intent.putExtra(Intent.EXTRA_LOCAL_ONLY, true);

		Intent chooser = Intent.createChooser(intent, "Select File");
		this.callback = callbackContext;
		try {
			cordova.startActivityForResult(this, chooser, LowcodeChooser.PICK_FILE_REQUEST);
		}
		catch (ActivityNotFoundException err) {
			// Stripped-down/enterprise ROMs can ship without a document picker.
			this.callback = null;
			callbackContext.error("No file picker available.");
			return;
		}

		PluginResult pluginResult = new PluginResult(PluginResult.Status.NO_RESULT);
		pluginResult.setKeepCallback(true);
		callbackContext.sendPluginResult(pluginResult);
	}

	@Override
	public void onActivityResult (int requestCode, int resultCode, final Intent data) {
		if (requestCode != LowcodeChooser.PICK_FILE_REQUEST || this.callback == null) {
			return;
		}

		final CallbackContext callbackContext = this.callback;
		this.callback = null;

		if (resultCode == Activity.RESULT_CANCELED) {
			callbackContext.success("RESULT_CANCELED");
			return;
		}
		if (resultCode != Activity.RESULT_OK) {
			callbackContext.error(resultCode);
			return;
		}
		if (data == null) {
			callbackContext.error("File URI was null.");
			return;
		}

		final ContentResolver contentResolver = this.cordova.getActivity().getContentResolver();

		// Provider queries can be slow (many files, remote-backed providers); keep them off the UI thread.
		cordova.getThreadPool().execute(new Runnable() {
			@Override
			public void run () {
				try {
					JSONArray result = new JSONArray();
					ClipData clipData = data.getClipData();

					if (clipData != null) {
						for (int i = 0; i < clipData.getItemCount(); i++) {
							LowcodeChooser.addFile(result, contentResolver, clipData.getItemAt(i).getUri());
						}
					} else {
						LowcodeChooser.addFile(result, contentResolver, data.getData());
					}

					if (result.length() == 0) {
						callbackContext.error("File URI was null.");
					} else {
						callbackContext.success(result.toString());
					}
				}
				catch (Exception err) {
					callbackContext.error("Failed to read file: " + err.toString());
				}
			}
		});
	}

	/**
	 * Low-memory devices can kill the app while the picker is open. Cordova then recreates
	 * the plugin and hands the result to this callback, which JS receives as
	 * `event.pendingResult` on the `resume` event.
	 */
	@Override
	public void onRestoreStateForActivityResult (Bundle state, CallbackContext callbackContext) {
		this.callback = callbackContext;
	}

	@Override
	public void onReset () {
		// The page that made the request is gone; drop its callback so a late result is not delivered to it.
		this.callback = null;
	}

	private static void addFile (JSONArray result, ContentResolver contentResolver, Uri uri) throws JSONException {
		if (uri != null) {
			result.put(LowcodeChooser.getFileFromUri(contentResolver, uri));
		}
	}

	private static JSONObject getFileFromUri (ContentResolver contentResolver, Uri uri) throws JSONException {
		JSONObject result = new JSONObject();

		String name = LowcodeChooser.getDisplayName(contentResolver, uri);

		String mediaType = null;
		try {
			mediaType = contentResolver.getType(uri);
		}
		catch (Exception err) {
			// Some providers throw instead of returning null; don't fail the whole selection.
		}
		if (mediaType == null || mediaType.isEmpty()) {
			mediaType = "application/octet-stream";
		}

		result.put("name", name);
		result.put("mimeType", mediaType);
		result.put("uri", uri.toString());
		return result;
	}

	/** @see https://stackoverflow.com/a/23270545/459881 */
	private static String getDisplayName (ContentResolver contentResolver, Uri uri) {
		String[] projection = {OpenableColumns.DISPLAY_NAME};
		String name = null;

		try {
			Cursor metaCursor = contentResolver.query(uri, projection, null, null, null);
			if (metaCursor != null) {
				try {
					if (metaCursor.moveToFirst()) {
						name = metaCursor.getString(0);
					}
				} finally {
					metaCursor.close();
				}
			}
		}
		catch (Exception err) {
			// Some providers reject metadata queries; the file itself is still usable.
		}

		return LowcodeChooser.sanitizeFileName(name);
	}

	/** The display name comes from the content provider and is untrusted. */
	private static String sanitizeFileName (String name) {
		if (name == null) {
			return LowcodeChooser.DEFAULT_NAME;
		}

		String sanitized = name.replaceAll("[\\\\/\\p{Cntrl}]", "_").trim();
		if (sanitized.isEmpty() || sanitized.equals(".") || sanitized.equals("..")) {
			return LowcodeChooser.DEFAULT_NAME;
		}
		return sanitized;
	}
}
