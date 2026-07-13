#!/usr/bin/env ruby
# frozen_string_literal: true

require 'xcodeproj'
require 'fileutils'

ROOT = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(ROOT, 'MKVPlayer.xcodeproj')
PACKAGE_RESOLVED_PATH = File.join(
  PROJECT_PATH,
  'project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
)
package_resolved = File.binread(PACKAGE_RESOLVED_PATH) if File.file?(PACKAGE_RESOLVED_PATH)

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes['LastSwiftUpdateCheck'] = '2620'
project.root_object.attributes['LastUpgradeCheck'] = '2620'

app_target = project.new_target(:application, 'MKVPlayer', :osx, '14.0')
test_target = project.new_target(:unit_test_bundle, 'MKVPlayerTests', :osx, '14.0')
test_target.add_dependency(app_target)

def add_local_package(project, target, relative_path, product_name)
  package = project.root_object.package_references.find do |reference|
    reference.isa == 'XCLocalSwiftPackageReference' && reference.relative_path == relative_path
  end
  unless package
    package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
    package.relative_path = relative_path
    project.root_object.package_references << package
  end

  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.package = package
  dependency.product_name = product_name
  target.package_product_dependencies << dependency

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dependency
  target.frameworks_build_phase.files << build_file
end

def add_remote_package(project, target, url, version, product_name)
  package = project.root_object.package_references.find do |reference|
    reference.isa == 'XCRemoteSwiftPackageReference' && reference.repositoryURL == url
  end
  unless package
    package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
    package.repositoryURL = url
    package.requirement = { 'kind' => 'exactVersion', 'version' => version }
    project.root_object.package_references << package
  end

  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.package = package
  dependency.product_name = product_name
  target.package_product_dependencies << dependency

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dependency
  target.frameworks_build_phase.files << build_file
end

add_local_package(project, app_target, 'Packages/PlayerCore', 'PlayerCore')
add_local_package(project, app_target, 'Packages/MPVKit', 'MPVKit')
add_local_package(project, test_target, 'Packages/PlayerCore', 'PlayerCore')
add_local_package(project, test_target, 'Packages/MPVKit', 'MPVKit')
add_remote_package(project, app_target, 'https://github.com/sparkle-project/Sparkle', '2.9.2', 'Sparkle')

app_group = project.main_group.new_group('App', 'App')
source_group = app_group.new_group('MKVPlayer', 'MKVPlayer')
tests_group = project.main_group.new_group('MKVPlayerTests', 'App/MKVPlayerTests')

media_core_path = File.join(ROOT, 'Vendor/MediaCore.xcframework')
if File.exist?(media_core_path)
  vendor_group = project.main_group.new_group('Vendor', 'Vendor')
  media_core_ref = vendor_group.new_file('MediaCore.xcframework')
  app_target.frameworks_build_phase.add_file_reference(media_core_ref)
  embed_phase = app_target.new_copy_files_build_phase('Embed Media Core')
  embed_phase.symbol_dst_subfolder_spec = :frameworks
  embed_file = embed_phase.add_file_reference(media_core_ref)
  embed_file.settings = { 'ATTRIBUTES' => %w[CodeSignOnCopy RemoveHeadersOnCopy] }
end

Dir.glob(File.join(ROOT, 'App/MKVPlayer/**/*.swift')).sort.each do |path|
  ref = source_group.new_file(path.delete_prefix("#{ROOT}/App/MKVPlayer/"))
  app_target.source_build_phase.add_file_reference(ref)
end

asset_path = File.join(ROOT, 'App/MKVPlayer/Resources/Assets.xcassets')
asset_ref = source_group.new_file('Resources/Assets.xcassets')
app_target.resources_build_phase.add_file_reference(asset_ref)

Dir.glob(File.join(ROOT, 'App/MKVPlayerTests/**/*.swift')).sort.each do |path|
  ref = tests_group.new_file(path.delete_prefix("#{ROOT}/App/MKVPlayerTests/"))
  test_target.source_build_phase.add_file_reference(ref)
end

project.build_configurations.each do |config|
  config.build_settings['CLANG_ENABLE_MODULES'] = 'YES'
  config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
  config.build_settings['SWIFT_VERSION'] = '6.0'
end

app_target.build_configurations.each do |config|
  settings = config.build_settings
  settings['ARCHS'] = '$(ARCHS_STANDARD)'
  settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  settings['CODE_SIGN_ENTITLEMENTS'] = 'App/MKVPlayer/MKVPlayer.entitlements'
  settings['COMBINE_HIDPI_IMAGES'] = 'YES'
  settings['CURRENT_PROJECT_VERSION'] = '1'
  settings['DEAD_CODE_STRIPPING'] = 'YES'
  settings['ENABLE_APP_SANDBOX'] = 'YES'
  settings['ENABLE_HARDENED_RUNTIME'] = config.name == 'Release' ? 'YES' : 'NO'
  settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'YES'
  settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  settings['INFOPLIST_FILE'] = 'App/MKVPlayer/Info.plist'
  settings['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/../Frameworks'
  settings['MARKETING_VERSION'] = '0.1.0'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'io.github.youssefsz.MKVPlayer'
  settings['PRODUCT_NAME'] = 'MKV Player'
  settings['SPARKLE_PUBLIC_ED_KEY'] = ''
  settings['SWIFT_STRICT_CONCURRENCY'] = 'complete'
end

test_target.build_configurations.each do |config|
  settings = config.build_settings
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'io.github.youssefsz.MKVPlayerTests'
  settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = \
    '$(inherited) $(MKVPLAYER_TEST_COMPILATION_CONDITION)'
  settings['SWIFT_STRICT_CONCURRENCY'] = 'complete'
  settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/MKV Player.app/Contents/MacOS/MKV Player'
  settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
end

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app_target)
scheme.add_test_target(test_target)
scheme.set_launch_target(app_target)
scheme.save_as(PROJECT_PATH, 'MKVPlayer', true)

project.predictabilize_uuids
project.save
if package_resolved
  FileUtils.mkdir_p(File.dirname(PACKAGE_RESOLVED_PATH))
  File.binwrite(PACKAGE_RESOLVED_PATH, package_resolved)
end
puts "Generated #{PROJECT_PATH}"
