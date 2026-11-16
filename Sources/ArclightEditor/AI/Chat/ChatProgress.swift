import ArclightCore
import SwiftUI

/// Plain words for the tools the AI calls, for the progress line and tool rows.
enum ChatToolNames {
    static let names: [String: (doing: String, done: String)] = [
        "web_search": ("Searching the web", "Searched the web"),
        "web_fetch": ("Reading a web page", "Read a web page"),
        "code_execution": ("Sorting the search results", "Sorted the search results"),
        "library_search": ("Looking in the free asset library", "Looked in the free asset library"),
        "library_import": ("Importing a free asset", "Imported a free asset"),
        "image_generate": ("Generating an image", "Generated an image"),
        "image_fill": ("Repainting an area", "Repainted an area"),
        "image_expand": ("Extending a picture", "Extended a picture"),
        "image_upscale": ("Upscaling a picture", "Upscaled a picture"),
        "image_remove_bg": ("Cutting out the subject", "Cut out the subject"),
        "image_depth": ("Making a depth map", "Made a depth map"),
        "image_select_subject": ("Finding the subject", "Found the subject"),
        "image_status": ("Checking the AI models", "Checked the AI models"),
        "model_generate": ("Making a 3D model (1–2 min)", "Made a 3D model"),
        "scene_create": ("Building the scene", "Built the scene"),
        "scene_apply": ("Editing the scene", "Edited the scene"),
        "scene_get": ("Reading the scene", "Read the scene"),
        "scene_delete": ("Deleting a scene", "Deleted a scene"),
        "render_frames": ("Rendering frames to check", "Checked the frames"),
        "thumbnail_create": ("Building the thumbnail", "Built the thumbnail"),
        "thumbnail_apply": ("Editing the thumbnail", "Edited the thumbnail"),
        "thumbnail_render": ("Rendering the thumbnail", "Checked the thumbnail"),
        "thumbnail_variants": ("Making variants", "Made variants"),
        "export": ("Exporting", "Exported"),
        "guide": ("Reading the guide", "Read the guide"),
        "project_get": ("Reading the project", "Read the project"),
        "editor_state": ("Looking at the editor", "Looked at the editor"),
        "reference_analyze": ("Studying the reference", "Studied the reference"),
        "asset_import": ("Importing a file", "Imported a file"),
        "theme_set": ("Setting the theme", "Set the theme"),
        "theme_apply": ("Applying the theme", "Applied the theme"),
        "project_check": ("Checking the project", "Checked the project"),
    ]

    static func doing(_ tool: String) -> String {
        names[tool]?.doing ?? tool.replacingOccurrences(of: "_", with: " ").capitalizedFirst
    }

    static func done(_ tool: String) -> String {
        names[tool]?.done ?? tool.replacingOccurrences(of: "_", with: " ").capitalizedFirst
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Pinned under the chat header: the AI's plan as a progress bar (goal, step n of m, what's happening now), opening
/// into the full step list. Without a plan, a running turn still shows what it is doing.
struct ChatProgress: View {
    @ObservedObject var chat: ChatController
    @AppStorage("chat.planOpen") private var open = false

    var body: some View {
        let plan = chat.transcript.plan
        let activity = chat.activity
        if plan != nil || activity != nil {
            VStack(alignment: .leading, spacing: 0) {
                if let plan { planView(plan, activity: activity) } else if let activity { live(activity) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(UI.raised.opacity(0.6))
            .overlay(alignment: .bottom) { Hairline() }
            .transition(.opacity)
        }
    }

    private func live(_ activity: String) -> some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.mini)
            Text(activity + "…").font(UI.small).foregroundStyle(UI.label2).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func planView(_ plan: ChatPlan, activity: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withMotion(Motion.snappy) { open.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(plan.goal.isEmpty ? "Plan" : plan.goal).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(UI.text).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(counter(plan)).font(UI.small).foregroundStyle(UI.dim).monospacedDigit()
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(UI.dim)
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                    bar(plan)
                    HStack(spacing: 6) {
                        statusIcon(plan, activity: activity)
                        Text(statusLine(plan, activity: activity)).font(UI.small).foregroundStyle(UI.label2)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).cursor(.pointingHand).help(open ? "Hide the steps" : "Show all steps")
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(plan.steps.enumerated()), id: \.offset) { i, step in row(i, step) }
                }
                .padding(.top, 2).transition(.opacity)
            }
        }
    }

    private func counter(_ plan: ChatPlan) -> String {
        if plan.isComplete { return "Done" }
        let n = (plan.activeIndex ?? plan.doneCount) + 1
        return "Step \(min(n, plan.steps.count)) of \(plan.steps.count)"
    }

    private func statusLine(_ plan: ChatPlan, activity: String?) -> String {
        if plan.isComplete { return "All \(plan.steps.count) steps done" }
        if plan.waiting && !chat.running { return "Waiting for your answer below" }
        let step = plan.current?.title ?? ""
        if let activity, chat.running { return step.isEmpty ? activity : "\(step) — \(activity.lowercased())" }
        if !chat.running { return step.isEmpty ? "Paused" : "Next: \(step)" }
        return step
    }

    @ViewBuilder private func statusIcon(_ plan: ChatPlan, activity: String?) -> some View {
        if plan.isComplete {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(UI.success)
        } else if plan.waiting && !chat.running {
            Image(systemName: "hand.raised.fill").font(.system(size: 9)).foregroundStyle(UI.warning)
        } else if chat.running {
            ProgressView().controlSize(.mini).frame(width: 10, height: 10)
        } else {
            Image(systemName: "pause.circle").font(.system(size: 10)).foregroundStyle(UI.dim)
        }
    }

    private func bar(_ plan: ChatPlan) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(UI.border)
                Capsule().fill(plan.isComplete ? UI.success : UI.ai)
                    .frame(width: max(4, g.size.width * plan.fraction))
                    .animation(Motion.snappy, value: plan.fraction)
            }
        }
        .frame(height: 4)
    }

    private func row(_ i: Int, _ step: ChatPlan.Step) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Group {
                switch step.status {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(UI.success)
                case .active:
                    if chat.running {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "circle.lefthalf.filled").foregroundStyle(UI.ai)
                    }
                case .skipped: Image(systemName: "minus.circle").foregroundStyle(UI.faint)
                case .pending: Image(systemName: "circle").foregroundStyle(UI.faint)
                }
            }
            .font(.system(size: 10)).frame(width: 12, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.title).font(UI.small)
                    .foregroundStyle(step.status == .pending || step.status == .skipped ? UI.dim : UI.text)
                    .strikethrough(step.status == .skipped)
                    .fontWeight(step.status == .active ? .semibold : .regular)
                if let n = step.note, !n.isEmpty {
                    Text(n).font(.system(size: 10.5)).foregroundStyle(UI.dim).fixedSize(
                        horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
