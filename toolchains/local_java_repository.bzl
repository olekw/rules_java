# Copyright 2021 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Rules for importing and registering a local JDK."""

load("@rules_java//java:defs.bzl", "java_runtime")
load(":default_java_toolchain.bzl", "default_java_toolchain")

def _detect_java_version(repository_ctx, java_bin):
    properties_out = repository_ctx.execute([java_bin, "-XshowSettings:properties"]).stderr
    # This returns an indented list of properties separated with newlines:
    # "  java.vendor.url.bug = ... \n"
    # "  java.version = 11.0.8\n"
    # "  java.version.date = 2020-11-05\"

    strip_properties = [property.strip() for property in properties_out.splitlines()]
    version_property = [property for property in strip_properties if property.startswith("java.version = ")]
    if len(version_property) != 1:
        return None

    version_value = version_property[0][len("java.version = "):]
    parts = version_value.split(".")
    major = parts[0]
    if len(parts) == 1:
        return major
    elif major == "1":  # handles versions below 1.8
        minor = parts[1]
        return minor
    return major

def local_java_runtime(name, java_home, version, runtime_name = None, visibility = ["//visibility:public"]):
    """Defines a java_runtime target together with Java runtime and compile toolchain definitions.

    Java runtime toolchain is constrained by flag --java_runtime_version having
    value set to either name or version argument.

    Java compile toolchains are created for --java_language_version flags values
    between 8 and version (inclusive). Java compile toolchains use the same
    (local) JDK for compilation. This requires a different configuration for JDK8
    than the newer versions.

    Args:
      name: name of the target.
      java_home: Path to the JDK.
      version: Version of the JDK.
      runtime_name: name of java_runtime target if it already exists.
      visibility: Visibility that will be applied to the java runtime target
    """

    if runtime_name == None:
        runtime_name = name
        java_runtime(
            name = runtime_name,
            java_home = java_home,
            visibility = visibility,
        )

    native.config_setting(
        name = name + "_name_setting",
        values = {"java_runtime_version": name},
        visibility = ["//visibility:private"],
    )
    native.config_setting(
        name = name + "_version_setting",
        values = {"java_runtime_version": version},
        visibility = ["//visibility:private"],
    )
    native.config_setting(
        name = name + "_name_version_setting",
        values = {"java_runtime_version": name + "_" + version},
        visibility = ["//visibility:private"],
    )
    native.alias(
        name = name + "_settings_alias",
        actual = select({
            ":" + name + "_name_setting": ":" + name + "_name_setting",
            ":" + name + "_version_setting": ":" + name + "_version_setting",
            "//conditions:default": ":" + name + "_name_version_setting",
        }),
        visibility = ["//visibility:private"],
    )
    native.toolchain(
        name = "runtime_toolchain_definition",
        target_settings = [":%s_settings_alias" % name],
        toolchain_type = "@bazel_tools//tools/jdk:runtime_toolchain_type",
        toolchain = runtime_name,
    )

    if type(version) == type("") and version.isdigit() and int(version) > 8:
        for version in range(8, int(version) + 1):
            default_java_toolchain(
                name = name + "_toolchain_java" + str(version),
                source_version = str(version),
                target_version = str(version),
                java_runtime = runtime_name,
            )

    # else version is not recognized and no compilation toolchains are predefined

def _is_macos(repository_ctx):
    return repository_ctx.os.name.lower().find("mac os x") != -1

def _is_windows(repository_ctx):
    return repository_ctx.os.name.lower().find("windows") != -1

def _with_os_extension(repository_ctx, binary):
    return binary + (".exe" if _is_windows(repository_ctx) else "")

def _determine_java_home(repository_ctx):
    """Determine the java home path.

    If the `java_home` attribute is specified, then use the given path,
    otherwise, try to detect the java home path on the system.

    Args:
      repository_ctx: repository context
    """
    java_home = repository_ctx.attr.java_home
    if java_home:
        java_home_path = repository_ctx.path(java_home)
        if not java_home_path.exists:
            fail('The path indicated by the "java_home" attribute "%s" (absolute: "%s") ' +
                 "does not exist." % (java_home, str(java_home_path)))
        return java_home_path
    if "JAVA_HOME" in repository_ctx.os.environ:
        return repository_ctx.path(repository_ctx.os.environ["JAVA_HOME"])

    if _is_macos(repository_ctx):
        # Replicate GetSystemJavabase() in src/main/cpp/blaze_util_darwin.cc
        result = repository_ctx.execute(["/usr/libexec/java_home", "-v", "1.11+"])
        if result.return_code == 0:
            return repository_ctx.path(result.stdout.strip())
    else:
        # Calculate java home by locating the javac binary
        # javac should exists at ${JAVA_HOME}/bin/javac
        # Replicate GetSystemJavabase() in src/main/cpp/blaze_util_linux.cc
        # This logic should also work on Windows.
        javac_path = repository_ctx.which(_with_os_extension(repository_ctx, "javac"))
        if javac_path:
            return javac_path.realpath.dirname.dirname
    return repository_ctx.path("./nosystemjdk")

def _local_java_repository_impl(repository_ctx):
    """Repository rule local_java_repository implementation.

    Args:
      repository_ctx: repository context
    """

    java_home = _determine_java_home(repository_ctx)

    repository_ctx.file(
        "WORKSPACE",
        "# DO NOT EDIT: automatically generated WORKSPACE file for local_java_repository\n" +
        "workspace(name = \"{name}\")\n".format(name = repository_ctx.name),
    )

    java_bin = java_home.get_child("bin").get_child(_with_os_extension(repository_ctx, "java"))

    if not java_bin.exists:
        # Java binary does not exist
        repository_ctx.file(
            "BUILD.bazel",
            _NOJDK_BUILD_TPL.format(
                local_jdk = repository_ctx.name,
                java_binary = _with_os_extension(repository_ctx, "bin/java"),
                java_home = java_home,
            ),
            False,
        )
        return

    # Detect version
    version = repository_ctx.attr.version if repository_ctx.attr.version != "" else _detect_java_version(repository_ctx, java_bin)

    # Prepare BUILD file using "local_java_runtime" macro
    build_file = ""
    if repository_ctx.attr.build_file != None:
        build_file = repository_ctx.read(repository_ctx.path(repository_ctx.attr.build_file))

    runtime_name = '"jdk"' if repository_ctx.attr.build_file else None
    local_java_runtime_macro = """
local_java_runtime(
    name = "%s",
    runtime_name = %s,
    java_home = "%s",
    version = "%s",
)
""" % (repository_ctx.attr.target_name, runtime_name, java_home, version)

    repository_ctx.file(
        "BUILD.bazel",
        'load("@rules_java//toolchains:local_java_repository.bzl", "local_java_runtime")\n' +
        build_file +
        local_java_runtime_macro,
    )

    # Symlink all files
    for file in java_home.readdir():
        repository_ctx.symlink(file, file.basename)

# Build file template, when JDK does not exist
_NOJDK_BUILD_TPL = '''load("@rules_java//toolchains:fail_rule.bzl", "fail_rule")
fail_rule(
   name = "jdk",
   header = "Auto-Configuration Error:",
   message = ("Cannot find Java binary {java_binary} in {java_home}; either correct your JAVA_HOME, " +
          "PATH or specify Java from remote repository (e.g. " +
          "--java_runtime_version=remotejdk_11")
)
config_setting(
   name = "localjdk_setting",
   values = {{"java_runtime_version": "{local_jdk}"}},
   visibility = ["//visibility:private"],
)
toolchain(
   name = "runtime_toolchain_definition",
   target_settings = [":localjdk_setting"],
   toolchain_type = "@bazel_tools//tools/jdk:runtime_toolchain_type",
   toolchain = ":jdk",
)
'''

_local_java_repository_rule = repository_rule(
    implementation = _local_java_repository_impl,
    local = True,
    configure = True,
    environ = ["JAVA_HOME"],
    attrs = {
        "build_file": attr.label(),
        "java_home": attr.string(),
        "target_name": attr.string(),
        "version": attr.string(),
    },
)

def local_java_repository(name, java_home = "", version = "", build_file = None):
    """Registers a runtime toolchain for local JDK and creates an unregistered compile toolchain.

    Toolchain resolution is constrained with --java_runtime_version flag
    having value of the "name" or "version" parameter.

    Java compile toolchains are created for --java_language_version flags values
    between 8 and version (inclusive). Java compile toolchains use the same
    (local) JDK for compilation.

    If there is no JDK "virtual" targets are created, which fail only when actually needed.

    Args:
      name: A unique name for this rule.
      java_home: Location of the JDK imported.
      build_file: optionally BUILD file template
      version: optionally java version
    """
    _local_java_repository_rule(
        name = name,
        target_name = name,
        java_home = java_home,
        version = version,
        build_file = build_file,
    )
