import type { PluginListenerHandle } from '@capacitor/core';

export interface YouTubeCapacitorPlugin {
  load(options: { videoId: string }): Promise<void>;
  play(): Promise<void>;
  pause(): Promise<void>;
  /** Play/pause decided by the native state; resolves with the new state. */
  toggle(): Promise<{ playing: boolean }>;
  /**
   * Playback state as the native player sees it. Used when the app returns to the
   * foreground, since the lock screen / Control Center may have changed it meanwhile.
   */
  getState(): Promise<{ playing: boolean; currentTime: number; duration: number; state: string }>;
  /** 'skip' = lock screen shows -10s/+10s, 'tracks' = previous/next track. */
  setLockScreenMode(options: { mode: 'skip' | 'tracks' }): Promise<void>;
  stop(): Promise<void>;
  seekTo(options: { seconds: number }): Promise<void>;
  setVolume(options: { volume: number }): Promise<void>;
  setUpNext(options: { items: Array<{ videoId: string; index: number; title: string; artist: string; duration: number; artworkUrl?: string }>; repeatOne: boolean }): Promise<void>;
  setTheme(options: { theme: 'dark' | 'light' | 'system' }): Promise<void>;
  setNowPlaying(options: { title: string; artist: string; duration: number; artworkUrl?: string; local?: boolean }): Promise<void>;

  addListener(
    eventName: 'youtubeStateChange',
    listenerFunc: (state: { state: string }) => void,
  ): Promise<PluginListenerHandle>;

  addListener(
    eventName: 'youtubeTimeUpdate',
    listenerFunc: (state: { currentTime: number, duration: number, videoId?: string }) => void,
  ): Promise<PluginListenerHandle>;
}
