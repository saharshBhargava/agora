require 'xcodeproj'
root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.new(File.join(root, 'Agora.xcodeproj'))
app = project.new_target(:application, 'Agora', :ios, '17.0')
app.product_name = 'Agora'
app.build_configurations.each do |config|
  config.build_settings.merge!({ 'PRODUCT_BUNDLE_IDENTIFIER' => 'dev.agora.browserchat', 'SWIFT_VERSION' => '5.0', 'GENERATE_INFOPLIST_FILE' => 'YES', 'INFOPLIST_FILE' => 'Agora/Info.plist', 'INFOPLIST_KEY_UILaunchScreen_Generation' => 'YES', 'INFOPLIST_KEY_UIApplicationSceneManifest_Generation' => 'YES', 'INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents' => 'YES', 'TARGETED_DEVICE_FAMILY' => '1,2', 'CODE_SIGN_STYLE' => 'Automatic', 'CURRENT_PROJECT_VERSION' => '1', 'MARKETING_VERSION' => '1.0', 'SWIFT_EMIT_LOC_STRINGS' => 'YES', 'INFOPLIST_KEY_NSCameraUsageDescription' => 'Agora uses the camera to take photos and record videos.', 'INFOPLIST_KEY_NSMicrophoneUsageDescription' => 'Agora uses the microphone to record sound with your videos.' })
end
config_ref = project.main_group.new_file('Config/Agora.xcconfig')
app.build_configurations.each { |config| config.base_configuration_reference = config_ref }
package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
package.repositoryURL = 'https://github.com/google/GoogleSignIn-iOS.git'
package.requirement = { 'kind' => 'exactVersion', 'version' => '9.2.0' }
project.root_object.package_references << package
['GoogleSignIn', 'GoogleSignInSwift'].each do |name|
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.package = package
  dep.product_name = name
  app.package_product_dependencies << dep
  build = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build.product_ref = dep
  app.frameworks_build_phase.files << build
end
Dir.glob(File.join(root, 'Agora/**/*')).select { |p| File.file?(p) && File.basename(p) != 'Info.plist' }.each do |path|
  ref = project.main_group.new_file(path.delete_prefix(root + '/'))
  path.end_with?('.swift') ? app.source_build_phase.add_file_reference(ref) : app.resources_build_phase.add_file_reference(ref)
end
tests = project.new_target(:unit_test_bundle, 'AgoraTests', :ios, '17.0')
tests.add_dependency(app)
tests.build_configurations.each do |config|
  config.build_settings.merge!({ 'PRODUCT_BUNDLE_IDENTIFIER' => 'dev.agora.browserchat.tests', 'SWIFT_VERSION' => '5.0', 'GENERATE_INFOPLIST_FILE' => 'YES', 'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/Agora.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Agora', 'BUNDLE_LOADER' => '$(TEST_HOST)', 'TARGETED_DEVICE_FAMILY' => '1,2' })
end
Dir.glob(File.join(root, 'AgoraTests/*.swift')).each { |p| tests.source_build_phase.add_file_reference(project.main_group.new_file(p.delete_prefix(root + '/'))) }
Dir.glob(File.join(root, 'Fixtures/*')).each { |p| tests.resources_build_phase.add_file_reference(project.main_group.new_file(p.delete_prefix(root + '/'))) }
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.set_launch_target(app)
scheme.save_as(project.path, 'Agora', true)
