Pod::Spec.new do |s|
  s.name = 'AudioStreaming'
  s.version = '1.2.3'
  s.license = 'MIT'
  s.summary = 'An AudioPlayer/Streaming library for iOS written in Swift using AVAudioEngine.'
  s.homepage = 'https://github.com/dimitris-c/AudioStreaming'
  s.authors = { 'Dimitris C.' => 'dimmdesign@gmail.com' }
  s.source = { :git => 'https://github.com/dimitris-c/AudioStreaming.git', :tag => s.version }

  s.ios.deployment_target = '13.0'

  s.swift_versions = ['5.1', '5.2', '5.3']

  s.source_files = 'AudioStreaming/**/*.swift'

  s.pod_target_xcconfig = {
    'SWIFT_INSTALL_OBJC_HEADER' => 'NO'
  }
end
