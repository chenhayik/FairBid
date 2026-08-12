import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// A tappable preview of a job's video: its first frame in a fixed-height
/// box with a play-icon overlay. Tapping opens a full-screen Chewie player.
/// Shared by the Post-a-Job form's attach preview
/// (`post_job/post_job_screen.dart`) and the job detail's Video section, so
/// both get the same first-frame-plus-play-button look and the same
/// full-screen playback, without a `video_thumbnail` dependency.
class JobVideoPreview extends StatefulWidget {
  const JobVideoPreview({super.key, required this.url, this.height = 160});

  final String url;
  final double height;

  @override
  State<JobVideoPreview> createState() => _JobVideoPreviewState();
}

class _JobVideoPreviewState extends State<JobVideoPreview> {
  late final VideoPlayerController _controller =
      VideoPlayerController.networkUrl(Uri.parse(widget.url));
  late final Future<void> _initFuture = _controller.initialize();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _openFullScreen() async {
    await _initFuture;
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _FullScreenVideoPlayer(controller: _controller),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: _openFullScreen,
        child: SizedBox(
          height: widget.height,
          width: double.infinity,
          child: ColoredBox(
            color: Colors.black,
            child: Stack(
              alignment: Alignment.center,
              children: [
                FutureBuilder<void>(
                  future: _initFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done ||
                        !_controller.value.isInitialized) {
                      return const CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white);
                    }
                    return FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: _controller.value.size.width,
                        height: _controller.value.size.height,
                        child: VideoPlayer(_controller),
                      ),
                    );
                  },
                ),
                const Icon(Icons.play_circle_fill,
                    color: Colors.white, size: 48),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-screen Chewie playback for a job video, pushed by [JobVideoPreview].
/// Owns only the [ChewieController]; the [VideoPlayerController] itself
/// belongs to (and is disposed by) the [JobVideoPreview] that pushed this
/// route.
class _FullScreenVideoPlayer extends StatefulWidget {
  const _FullScreenVideoPlayer({required this.controller});
  final VideoPlayerController controller;

  @override
  State<_FullScreenVideoPlayer> createState() =>
      _FullScreenVideoPlayerState();
}

class _FullScreenVideoPlayerState extends State<_FullScreenVideoPlayer> {
  late final ChewieController _chewie = ChewieController(
    videoPlayerController: widget.controller,
    autoPlay: true,
    looping: false,
  );

  @override
  void dispose() {
    // Chewie 1.14.1's ChewieController.dispose() doesn't touch the
    // underlying VideoPlayerController, and that controller is shared with
    // (and owned by) the JobVideoPreview below this route - so without this,
    // popping the full-screen player leaves the video playing, with audio,
    // behind a thumbnail that's supposed to be a static first frame. Pause
    // and rewind it before releasing Chewie's controls; these are
    // fire-and-forget (dispose() can't be async), but the platform channel
    // preserves call order, so the pause always lands before the seek.
    widget.controller.pause();
    widget.controller.seekTo(Duration.zero);
    _chewie.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Center(child: Chewie(controller: _chewie)),
    );
  }
}
