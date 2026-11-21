# Adds the Packet Tunnel extension (ios/PacketTunnel) to the Flutter Runner project, links it with
# Libbox.xcframework (sing-box, built in CI) and NetworkExtension, embeds it into the app, and adds
# ios/Runner/VpnChannel.swift plus the app's entitlements to Runner. Runs in CI on macOS before
# `flutter build ios`; it is idempotent, so running it twice changes nothing.
#
# usage: ruby add_tunnel_target.rb ios/Runner.xcodeproj <version> <build>
require 'xcodeproj'

project_path, version, build = ARGV
version ||= '1.0.0'
build ||= '1'
project = Xcodeproj::Project.open(project_path)
runner = project.targets.find { |t| t.name == 'Runner' } or abort 'no Runner target'

# Runner: the channel to the tunnel and the entitlements
runner_group = project.main_group.find_subpath('Runner', false) or abort 'no Runner group'
unless runner_group.files.any? { |f| f.path == 'VpnChannel.swift' }
  ref = runner_group.new_reference('VpnChannel.swift')
  runner.add_file_references([ref])
end
runner_group.new_reference('Runner.entitlements') unless runner_group.files.any? { |f| f.path == 'Runner.entitlements' }

ne = project.frameworks_group.files.find { |f| f.path&.end_with?('NetworkExtension.framework') } ||
     project.frameworks_group.new_file('System/Library/Frameworks/NetworkExtension.framework', :sdk_root)
runner.frameworks_build_phase.add_file_reference(ne, true)
runner.build_configurations.each do |c|
  c.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
  c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
end

ext = project.targets.find { |t| t.name == 'PacketTunnel' }
unless ext
  ext = project.new_target(:app_extension, 'PacketTunnel', :ios, '15.0', nil, :swift)
  group = project.main_group.find_subpath('PacketTunnel', true)
  group.set_source_tree('<group>')
  group.set_path('PacketTunnel')
  Dir.glob(File.join(File.dirname(project_path), 'PacketTunnel', '*.swift')).sort.each do |f|
    ext.add_file_references([group.new_reference(File.basename(f))])
  end
  group.new_reference('Info.plist')
  group.new_reference('PacketTunnel.entitlements')

  libbox = project.frameworks_group.new_reference('Libbox.xcframework')
  libbox.source_tree = 'SOURCE_ROOT'
  libbox.last_known_file_type = 'wrapper.xcframework'
  ext.frameworks_build_phase.add_file_reference(libbox, true)
  ext.frameworks_build_phase.add_file_reference(ne, true)

  # embed the extension into the app; the phase must come before Flutter's script phases ("Thin Binary"),
  # otherwise Xcode reports a dependency cycle
  embed = runner.new_copy_files_build_phase('Embed Foundation Extensions')
  embed.symbol_dst_subfolder_spec = :plug_ins
  bf = embed.add_file_reference(ext.product_reference, true)
  bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
  runner.build_phases.delete(embed)
  idx = runner.build_phases.index { |p| p.is_a?(Xcodeproj::Project::Object::PBXResourcesBuildPhase) } || 0
  runner.build_phases.insert(idx + 1, embed)
  runner.add_dependency(ext)
end

ext.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'io.github.dovletix.vlessclient.PacketTunnel'
  s['INFOPLIST_FILE'] = 'PacketTunnel/Info.plist'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['CODE_SIGN_ENTITLEMENTS'] = 'PacketTunnel/PacketTunnel.entitlements'
  s['SWIFT_VERSION'] = '5.0'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['MARKETING_VERSION'] = version
  s['CURRENT_PROJECT_VERSION'] = build
  s['SKIP_INSTALL'] = 'YES'
  s['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  s['ENABLE_BITCODE'] = 'NO'
  s['OTHER_LDFLAGS'] = ['$(inherited)', '-lresolv']
  s['FRAMEWORK_SEARCH_PATHS'] = ['$(inherited)', '$(PROJECT_DIR)']
  s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
end

project.save
puts "PacketTunnel target ready (#{version} / #{build})"
