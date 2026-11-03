load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")

swift_library(
    name = "TelegramEnvelopes",
    module_name = "TelegramEnvelopes",
    srcs = glob(["Sources/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    visibility = ["//visibility:public"],
)

swift_test(
    name = "TelegramEnvelopesTests",
    srcs = glob(["Tests/**/*.swift"]),
    deps = [":TelegramEnvelopes"],
)
