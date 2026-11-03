load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "ChatMessageEnvelopeBubbleContentNode",
    module_name = "ChatMessageEnvelopeBubbleContentNode",
    srcs = glob(["Sources/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    deps = [
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/LottieSettings:LottieSettings",
        "//submodules/TelegramCore",
        "//submodules/TelegramEnvelopes",
        "//submodules/TelegramPresentationData",
        "//submodules/WallpaperBackgroundNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageBubbleContentNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageItemCommon",
        "//submodules/TelegramUI/Components/Envelopes/EnvelopeRendering",
    ],
    visibility = ["//visibility:public"],
)
