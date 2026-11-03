load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "EnvelopeRendering",
    module_name = "EnvelopeRendering",
    srcs = glob(["Sources/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    deps = [
        "//submodules/Display",
        "//submodules/TelegramEnvelopes",
        "//submodules/AppBundle",
        "//submodules/TelegramPresentationData",
    ],
    visibility = ["//visibility:public"],
)
