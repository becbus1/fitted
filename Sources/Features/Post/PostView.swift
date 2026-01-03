import SwiftUI
import UIKit

// MARK: - Post View
// Daily check-in screen. Resolves social pressure from CircleView.
// Effortless, finite, non-performative.
// One photo per day. No captions. No filters. No edits.

struct PostView: View {
    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - Callbacks

    /// Called after successful post.
    /// TODO: Wire to actual upload and CircleView return.
    var onPostComplete: () -> Void = {}

    // MARK: - State

    @State private var capturedImage: UIImage?
    @State private var postState: PostState = .camera
    @State private var showingCamera = false

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                FittedColors.backgroundPrimary
                    .ignoresSafeArea()

                switch postState {
                case .camera:
                    cameraPromptView

                case .preview:
                    if let image = capturedImage {
                        previewView(image: image)
                    }

                case .posting:
                    postingView

                case .complete:
                    completeView
                }
            }
            .navigationTitle("Today's fit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if postState == .camera || postState == .preview {
                        Button("Cancel") {
                            dismiss()
                        }
                        .foregroundStyle(FittedColors.textSecondary)
                    }
                }
            }
            .sheet(isPresented: $showingCamera) {
                CameraView(image: $capturedImage)
                    .ignoresSafeArea()
            }
            .onChange(of: capturedImage) { _, newValue in
                if newValue != nil {
                    postState = .preview
                }
            }
        }
    }

    // MARK: - Camera Prompt View
    // Initial state. Invites user to take today's photo.

    private var cameraPromptView: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 12) {
                Text("Post once per day")
                    .font(FittedTypography.body)
                    .foregroundStyle(FittedColors.textSecondary)

                Text("No filters. No captions.")
                    .font(FittedTypography.caption)
                    .foregroundStyle(FittedColors.textTertiary)
            }

            Spacer()

            // Capture button
            Button(action: { showingCamera = true }) {
                ZStack {
                    Circle()
                        .strokeBorder(FittedColors.textPrimary, lineWidth: 3)
                        .frame(width: 72, height: 72)

                    Circle()
                        .fill(FittedColors.textPrimary)
                        .frame(width: 60, height: 60)
                }
            }

            Spacer()
                .frame(height: 60)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Preview View
    // Shows captured image. Allows posting or retaking.
    // Retake is allowed BEFORE posting only.

    private func previewView(image: UIImage) -> some View {
        VStack(spacing: 24) {
            Spacer()
                .frame(height: 16)

            // Image preview
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 24)

            Spacer()

            // Actions
            VStack(spacing: 12) {
                // Post button
                Button(action: submitPost) {
                    Text("Post")
                        .font(FittedTypography.body)
                        .foregroundStyle(FittedColors.backgroundPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(FittedColors.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                // Retake button (only before posting)
                Button(action: retakePhoto) {
                    Text("Retake")
                        .font(FittedTypography.body)
                        .foregroundStyle(FittedColors.textSecondary)
                }
            }
            .padding(.horizontal, 32)

            Spacer()
                .frame(height: 32)
        }
    }

    // MARK: - Posting View
    // Brief loading state during upload.

    private var postingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(FittedColors.textSecondary)

            Text("Posting...")
                .font(FittedTypography.caption)
                .foregroundStyle(FittedColors.textTertiary)
        }
    }

    // MARK: - Complete View
    // Subtle confirmation. Relief, not celebration.
    // Auto-dismisses after brief delay.

    private var completeView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(FittedColors.accent)

            Text("Posted")
                .font(FittedTypography.body)
                .foregroundStyle(FittedColors.textPrimary)

            Text("You're done for today")
                .font(FittedTypography.caption)
                .foregroundStyle(FittedColors.textTertiary)
        }
        .onAppear {
            // Light haptic feedback
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)

            // Auto-dismiss after brief moment
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                onPostComplete()
                dismiss()
            }
        }
    }

    // MARK: - Actions

    private func submitPost() {
        postState = .posting

        // TODO: Wire to actual image upload service.
        // Upload to Supabase Storage, then create post record.
        // For now, simulate upload delay.

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            postState = .complete
        }
    }

    private func retakePhoto() {
        capturedImage = nil
        postState = .camera
        showingCamera = true
    }
}

// MARK: - Post State

private enum PostState {
    case camera     // Initial: ready to capture
    case preview    // Image captured, ready to post
    case posting    // Upload in progress
    case complete   // Done for today
}

// MARK: - Camera View
// Native iOS camera via UIImagePickerController.
// No filters. No editing. Just capture.

struct CameraView: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        picker.cameraDevice = .rear
        picker.allowsEditing = false
        picker.showsCameraControls = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView

        init(_ parent: CameraView) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.image = image
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Simulator Fallback
// For development: use photo library if camera unavailable.

extension CameraView {
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }
}

// MARK: - Preview

#Preview("Camera Prompt") {
    PostView()
}

#Preview("Complete State") {
    // For previewing completion state
    PostView()
}
