package com.arsync.camerabridge;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.pm.PackageManager;
import android.graphics.Matrix;
import android.graphics.Color;
import android.graphics.SurfaceTexture;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.media.MediaRecorder;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Size;
import android.view.Gravity;
import android.view.Surface;
import android.view.TextureView;
import android.view.View;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.Toast;

import java.io.File;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;

public final class MainActivity extends Activity {
    private static final int REQUEST_PERMISSIONS = 7;
    private TextureView preview;
    private FrameLayout root;
    private Button recordButton;
    private CameraManager cameraManager;
    private CameraDevice camera;
    private CameraCaptureSession session;
    private Size previewSize;
    private String cameraId;
    private Handler cameraHandler;
    private HandlerThread cameraThread;
    private MediaRecorder recorder;
    private boolean isRecording;

    private final TextureView.SurfaceTextureListener textureListener = new TextureView.SurfaceTextureListener() {
        @Override public void onSurfaceTextureAvailable(SurfaceTexture surface, int width, int height) {
            openCamera(width, height);
        }
        @Override public void onSurfaceTextureSizeChanged(SurfaceTexture surface, int width, int height) {
            applyPreviewTransform(width, height);
        }
        @Override public boolean onSurfaceTextureDestroyed(SurfaceTexture surface) { return true; }
        @Override public void onSurfaceTextureUpdated(SurfaceTexture surface) {}
    };

    private final CameraDevice.StateCallback cameraCallback = new CameraDevice.StateCallback() {
        @Override public void onOpened(CameraDevice device) {
            camera = device;
            createPreviewSession();
        }
        @Override public void onDisconnected(CameraDevice device) {
            device.close();
            camera = null;
        }
        @Override public void onError(CameraDevice device, int error) {
            device.close();
            camera = null;
            showMessage("Camera error " + error);
        }
    };

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().setFlags(1024, 1024);
        getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                        | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_LAYOUT_STABLE);

        root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        preview = new TextureView(this);
        root.addView(preview, new FrameLayout.LayoutParams(-1, -1));

        recordButton = new Button(this);
        recordButton.setText("REC");
        recordButton.setTextColor(0xFFFFFFFF);
        recordButton.setTextSize(14);
        // Keep the large hit target for Avdpane's right-side shutter mapping,
        // but do not paint a debug control over the live camera image.
        recordButton.setAlpha(0.0f);
        recordButton.setOnClickListener(view -> toggleRecording());
        FrameLayout.LayoutParams buttonParams = new FrameLayout.LayoutParams(180, 96);
        buttonParams.gravity = Gravity.RIGHT | Gravity.CENTER_VERTICAL;
        buttonParams.setMargins(0, 0, 32, 0);
        root.addView(recordButton, buttonParams);
        setContentView(root);

        cameraManager = (CameraManager) getSystemService(Context.CAMERA_SERVICE);
        if (hasPermissions()) {
            startCameraThread();
        } else {
            requestPermissions(new String[]{Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO}, REQUEST_PERMISSIONS);
        }
    }

    @Override protected void onResume() {
        super.onResume();
        if (cameraThread == null && hasPermissions()) startCameraThread();
        if (preview != null && preview.isAvailable() && camera == null && hasPermissions()) {
            openCamera(preview.getWidth(), preview.getHeight());
        } else if (preview != null) {
            preview.setSurfaceTextureListener(textureListener);
        }
    }

    @Override protected void onPause() {
        stopRecording();
        closeCamera();
        stopCameraThread();
        super.onPause();
    }

    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] grants) {
        super.onRequestPermissionsResult(request, permissions, grants);
        if (request == REQUEST_PERMISSIONS && hasPermissions()) {
            startCameraThread();
            if (preview != null) preview.setSurfaceTextureListener(textureListener);
        } else {
            showMessage("Camera permission is required");
        }
    }

    private boolean hasPermissions() {
        return checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
                && checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED;
    }

    private void startCameraThread() {
        if (cameraThread != null) return;
        cameraThread = new HandlerThread("CameraBridge");
        cameraThread.start();
        cameraHandler = new Handler(cameraThread.getLooper());
        if (preview != null) preview.setSurfaceTextureListener(textureListener);
    }

    private void stopCameraThread() {
        if (cameraThread == null) return;
        cameraThread.quitSafely();
        try { cameraThread.join(); } catch (InterruptedException ignored) { Thread.currentThread().interrupt(); }
        cameraThread = null;
        cameraHandler = null;
    }

    private void openCamera(int viewWidth, int viewHeight) {
        if (!hasPermissions() || cameraHandler == null) return;
        try {
            for (String id : cameraManager.getCameraIdList()) {
                CameraCharacteristics characteristics = cameraManager.getCameraCharacteristics(id);
                Integer facing = characteristics.get(CameraCharacteristics.LENS_FACING);
                if (facing != null && facing == CameraCharacteristics.LENS_FACING_BACK) {
                    cameraId = id;
                    android.hardware.camera2.params.StreamConfigurationMap map =
                            characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
                    if (map == null) return;
                    previewSize = choosePreviewSize(map.getOutputSizes(SurfaceTexture.class));
                    applyPreviewTransform(viewWidth, viewHeight);
                    cameraManager.openCamera(cameraId, cameraCallback, cameraHandler);
                    return;
                }
            }
        } catch (CameraAccessException | SecurityException error) {
            showMessage("Unable to open camera");
        }
    }

    private Size choosePreviewSize(Size[] sizes) {
        List<Size> candidates = new ArrayList<>(Arrays.asList(sizes));
        Collections.sort(candidates, (left, right) -> Long.compare(area(right), area(left)));
        Size best = null;
        // Match the emulator Camera app's native landscape stream.  The
        // display transform below rotates this 16:9 buffer with the device
        // instead of stretching it into the current screen orientation.
        double target = 16.0 / 9.0;
        for (Size size : candidates) {
            if (size.getWidth() == 1280 && size.getHeight() == 720) return size;
        }
        double bestDifference = Double.MAX_VALUE;
        for (Size size : candidates) {
            if (size.getWidth() > 1920 || size.getHeight() > 1080) continue;
            double difference = Math.abs((double) size.getWidth() / size.getHeight() - target);
            if (difference < bestDifference) {
                best = size;
                bestDifference = difference;
            }
        }
        return best != null ? best : candidates.get(0);
    }

    private long area(Size size) {
        return (long) size.getWidth() * size.getHeight();
    }

    private void applyPreviewTransform(int viewWidth, int viewHeight) {
        if (preview == null || previewSize == null || viewWidth == 0 || viewHeight == 0) return;
        int rotation = getWindowManager().getDefaultDisplay().getRotation();
        int degrees = rotation == Surface.ROTATION_90 ? 90
                : rotation == Surface.ROTATION_180 ? 180
                : rotation == Surface.ROTATION_270 ? 270 : 0;
        boolean swapsAxes = degrees == 90 || degrees == 270;
        float bufferWidth = swapsAxes ? previewSize.getHeight() : previewSize.getWidth();
        float bufferHeight = swapsAxes ? previewSize.getWidth() : previewSize.getHeight();
        // The camera stream is 1280x720.  After a 90-degree display rotation
        // its displayed size is 720x1280; it must never be resized independently
        // on the two axes.  Fill the TextureView with one uniform scale and
        // crop the excess at the edges.  This is the same aspect-ratio behavior
        // as a normal camera preview and avoids stretching faces/hands.
        float scale = Math.max(viewWidth / bufferWidth, viewHeight / bufferHeight);
        FrameLayout.LayoutParams params = (FrameLayout.LayoutParams) preview.getLayoutParams();
        if (params.width != -1 || params.height != -1 || params.gravity != Gravity.NO_GRAVITY) {
            params.width = -1;
            params.height = -1;
            params.gravity = Gravity.NO_GRAVITY;
            preview.setLayoutParams(params);
        }
        Matrix transform = new Matrix();
        transform.setTranslate(-previewSize.getWidth() / 2.0f, -previewSize.getHeight() / 2.0f);
        transform.postRotate(degrees);
        transform.postScale(scale, scale);
        transform.postTranslate(viewWidth / 2.0f, viewHeight / 2.0f);
        preview.setTransform(transform);
    }

    @Override public void onConfigurationChanged(android.content.res.Configuration configuration) {
        super.onConfigurationChanged(configuration);
        if (preview != null && preview.isAvailable()) {
            preview.post(() -> applyPreviewTransform(preview.getWidth(), preview.getHeight()));
        }
    }

    private void createPreviewSession() {
        if (camera == null || preview.getSurfaceTexture() == null) return;
        try {
            SurfaceTexture texture = preview.getSurfaceTexture();
            texture.setDefaultBufferSize(previewSize.getWidth(), previewSize.getHeight());
            Surface surface = new Surface(texture);
            CaptureRequest.Builder request = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
            request.addTarget(surface);
            request.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO);
            camera.createCaptureSession(Collections.singletonList(surface), new CameraCaptureSession.StateCallback() {
                @Override public void onConfigured(CameraCaptureSession value) {
                    session = value;
                    try { session.setRepeatingRequest(request.build(), null, cameraHandler); }
                    catch (CameraAccessException error) { showMessage("Preview failed"); }
                }
                @Override public void onConfigureFailed(CameraCaptureSession value) { showMessage("Preview failed"); }
            }, cameraHandler);
        } catch (CameraAccessException error) {
            showMessage("Preview failed");
        }
    }

    private void toggleRecording() {
        if (isRecording) stopRecording(); else startRecording();
    }

    private void startRecording() {
        if (camera == null || preview.getSurfaceTexture() == null) return;
        try {
            recorder = new MediaRecorder();
            recorder.setAudioSource(MediaRecorder.AudioSource.MIC);
            recorder.setVideoSource(MediaRecorder.VideoSource.SURFACE);
            recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);
            File dir = getExternalFilesDir(Environment.DIRECTORY_MOVIES);
            if (dir == null) throw new IOException("No movie directory");
            recorder.setOutputFile(new File(dir, "camera-" + System.currentTimeMillis() + ".mp4").getAbsolutePath());
            recorder.setVideoEncodingBitRate(6_000_000);
            recorder.setVideoFrameRate(30);
            recorder.setVideoSize(previewSize.getWidth(), previewSize.getHeight());
            recorder.setVideoEncoder(MediaRecorder.VideoEncoder.H264);
            recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC);
            recorder.prepare();

            SurfaceTexture texture = preview.getSurfaceTexture();
            texture.setDefaultBufferSize(previewSize.getWidth(), previewSize.getHeight());
            Surface previewSurface = new Surface(texture);
            Surface recorderSurface = recorder.getSurface();
            CaptureRequest.Builder request = camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD);
            request.addTarget(previewSurface);
            request.addTarget(recorderSurface);
            camera.createCaptureSession(Arrays.asList(previewSurface, recorderSurface), new CameraCaptureSession.StateCallback() {
                @Override public void onConfigured(CameraCaptureSession value) {
                    session = value;
                    try {
                        session.setRepeatingRequest(request.build(), null, cameraHandler);
                        recorder.start();
                        isRecording = true;
                        recordButton.setText("STOP");
                    } catch (CameraAccessException error) {
                        stopRecording();
                    }
                }
                @Override public void onConfigureFailed(CameraCaptureSession value) { stopRecording(); }
            }, cameraHandler);
        } catch (IOException | CameraAccessException error) {
            releaseRecorder();
            showMessage("Recording failed");
        }
    }

    private void stopRecording() {
        if (!isRecording && recorder == null) return;
        isRecording = false;
        if (session != null) {
            try { session.stopRepeating(); } catch (CameraAccessException ignored) {}
            session.close();
            session = null;
        }
        if (recorder != null) {
            try { recorder.stop(); } catch (RuntimeException ignored) {}
            releaseRecorder();
        }
        if (recordButton != null) recordButton.setText("REC");
        if (camera != null) createPreviewSession();
    }

    private void releaseRecorder() {
        if (recorder == null) return;
        recorder.reset();
        recorder.release();
        recorder = null;
    }

    private void closeCamera() {
        if (session != null) { session.close(); session = null; }
        if (camera != null) { camera.close(); camera = null; }
        releaseRecorder();
    }

    private void showMessage(String message) {
        runOnUiThread(() -> Toast.makeText(this, message, Toast.LENGTH_SHORT).show());
    }
}
