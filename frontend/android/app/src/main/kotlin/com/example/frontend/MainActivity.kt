package com.example.frontend

import com.ryanheise.audioservice.AudioServiceFragmentActivity

// AudioServiceFragmentActivity = FlutterFragmentActivity (biometrics keep
// working) + the media-session plumbing background playback needs.
class MainActivity: AudioServiceFragmentActivity() {
}
