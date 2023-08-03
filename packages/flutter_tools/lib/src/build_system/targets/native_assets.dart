// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:native_assets_cli/native_assets_cli.dart' show Asset;

import '../../base/file_system.dart';
import '../../base/platform.dart';
import '../../build_info.dart';
import '../../globals.dart' as globals;
import '../../ios/native_assets.dart';
import '../../macos/native_assets.dart';
import '../../macos/xcode.dart';
import '../../native_assets.dart';
import '../build_system.dart';
import '../depfile.dart';
import '../exceptions.dart';
import 'common.dart';

/// Builds the right native assets for a Flutter app.
///
/// Because the build mode and target architecture can be changed from the
/// native build project (Xcode etc.), we can only build the native assets
/// inside `flutter assemble` when we have all the information.
///
/// All the other invocations for native assets should be dry runs.
///
/// This step needs to be consistent with the other invocations so that the
/// kernel mapping of asset id to dylib lines up after hot restart, and so
/// that the dylibs are bundled by the native build.
///
/// We don't have [NativeAssets] as a dependency of [KernelSnapshot], because
/// it would cause rebuilds of the kernel snapshot due to native assets being
/// rebuilt. The native assets build caching is inside
/// `package:native_assets_builder` and not visible to the flutter targets.
/// This means we don't produce a native_assets.yaml here, and instead rely on
/// the file being pointed to in the native build properties file which is set
/// by build_macos.dart and friends.
class NativeAssets extends Target {
  const NativeAssets();

  @override
  Future<void> build(Environment environment) async {
    final String? targetPlatformEnvironment =
        environment.defines[kTargetPlatform];
    if (targetPlatformEnvironment == null) {
      throw MissingDefineException(kTargetPlatform, name);
    }
    final TargetPlatform targetPlatform =
        getTargetPlatformForName(targetPlatformEnvironment);

    final Uri projectUri = environment.projectDir.uri;
    final FileSystem fileSystem = globals.fs;
    final NativeAssetsBuildRunner buildRunner =
        NativeAssetsBuildRunnerImpl(projectUri, fileSystem);

    globals.logger.printTrace(
        'Potentially writing native_assets.yaml to: ${environment.buildDir.path}');

    List<Uri> dependencies = <Uri>[];
    switch (targetPlatform) {
      case TargetPlatform.ios:
        final String? iosArchsEnvironment = environment.defines[kIosArchs];
        if (iosArchsEnvironment == null) {
          throw MissingDefineException(kIosArchs, name);
        }
        final List<DarwinArch> iosArchs =
            iosArchsEnvironment
            .split(' ')
            .map(getDarwinArchForName)
            .toList();
        final String? environmentBuildMode = environment.defines[kBuildMode];
        if (environmentBuildMode == null) {
          throw MissingDefineException(kBuildMode, name);
        }
        final BuildMode buildMode = BuildMode.fromCliName(environmentBuildMode);
        final String? sdkRoot = environment.defines[kSdkRoot];
        if (sdkRoot == null) {
          throw MissingDefineException(kSdkRoot, name);
        }
        final EnvironmentType environmentType =
            environmentTypeFromSdkroot(sdkRoot, environment.fileSystem)!;
        dependencies = await buildNativeAssetsiOS(
          environmentType: environmentType,
          darwinArchs: iosArchs,
          buildMode: buildMode,
          projectUri: projectUri,
          codesignIdentity: environment.defines[kCodesignIdentity],
          fileSystem: fileSystem,
          buildRunner: buildRunner,
          writeYamlFileTo: environment.buildDir.uri,
        );
      case TargetPlatform.darwin:
        final String? darwinArchsEnvironment =
            environment.defines[kDarwinArchs];
        if (darwinArchsEnvironment == null) {
          throw MissingDefineException(kDarwinArchs, name);
        }
        final List<DarwinArch> darwinArchs = darwinArchsEnvironment
            .split(' ')
            .map(getDarwinArchForName)
            .toList();
        final String? environmentBuildMode = environment.defines[kBuildMode];
        if (environmentBuildMode == null) {
          throw MissingDefineException(kBuildMode, name);
        }
        final BuildMode buildMode = BuildMode.fromCliName(environmentBuildMode);
        (_, dependencies) = await buildNativeAssetsMacOS(
          darwinArchs: darwinArchs,
          buildMode: buildMode,
          projectUri: projectUri,
          codesignIdentity: environment.defines[kCodesignIdentity],
          writeYamlFileTo: environment.buildDir.uri,
          fileSystem: fileSystem,
          buildRunner: buildRunner,
        );
      case TargetPlatform.tester:
        if (const LocalPlatform().isMacOS) {
          (_, dependencies) = await buildNativeAssetsMacOS(
            buildMode: BuildMode.debug,
            projectUri: projectUri,
            codesignIdentity: environment.defines[kCodesignIdentity],
            writeYamlFileTo: environment.buildDir.uri,
            fileSystem: fileSystem,
            buildRunner: buildRunner,
            flutterTester: true,
          );
        } else {
          // TODO(dacoharkes): Implement other OSes. https://github.com/flutter/flutter/issues/129757
          // Write the file we claim to have in the [outputs].
          await writeNativeAssetsYaml(
              <Asset>[], environment.buildDir.uri, fileSystem);
        }
      case TargetPlatform.android_arm:
      case TargetPlatform.android_arm64:
      case TargetPlatform.android_x64:
      case TargetPlatform.android_x86:
      case TargetPlatform.android:
      case TargetPlatform.fuchsia_arm64:
      case TargetPlatform.fuchsia_x64:
      case TargetPlatform.linux_arm64:
      case TargetPlatform.linux_x64:
      case TargetPlatform.web_javascript:
      case TargetPlatform.windows_x64:
        // TODO(dacoharkes): Implement other OSes. https://github.com/flutter/flutter/issues/129757
        // Write the file we claim to have in the [outputs].
        await writeNativeAssetsYaml(
            <Asset>[], environment.buildDir.uri, fileSystem);
    }

    final Depfile depfile = Depfile(
      <File>[
        for (final Uri dependency in dependencies) fileSystem.file(dependency),
      ],
      <File>[
        environment.buildDir.childFile('native_assets.yaml'),
      ],
    );
    final File outputDepfile =
        environment.buildDir.childFile('native_assets.d');
    if (!outputDepfile.parent.existsSync()) {
      outputDepfile.parent.createSync(recursive: true);
    }
    environment.depFileService.writeToFile(depfile, outputDepfile);
  }

  @override
  List<String> get depfiles => <String>[
        'native_assets.d',
      ];

  @override
  List<Target> get dependencies => <Target>[];

  @override
  List<Source> get inputs => const <Source>[
        Source.pattern(
            '{FLUTTER_ROOT}/packages/flutter_tools/lib/src/build_system/targets/native_assets.dart'),
        // If different packages are resolved, different native assets might need to be built.
        Source.pattern('{PROJECT_DIR}/.dart_tool/package_config_subset'),
      ];

  @override
  String get name => 'native_assets';

  @override
  List<Source> get outputs => const <Source>[
        Source.pattern('{BUILD_DIR}/native_assets.yaml'),
      ];
}