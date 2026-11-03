load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "EnvelopeDemoScreen",
    module_name = "EnvelopeDemoScreen",
    srcs = glob(["Sources/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    deps = [
        "//submodules/Display",
        "//submodules/TelegramCore",
        "//submodules/TelegramEnvelopes",
        "//submodules/TelegramPresentationData",
        "//submodules/AccountContext",
        "//submodules/TelegramUI/Components/Envelopes/EnvelopeRendering",
    ],
    visibility = ["//visibility:public"],
)
