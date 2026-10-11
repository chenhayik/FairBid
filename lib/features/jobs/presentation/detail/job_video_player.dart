import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// What:   Tappable preview of a job's video.
/// Input:  [url] from job.videoUrl.
/// Output: First frame with a play icon; tapping opens a full-screen Chewie player.
class JobVideoPreview extends StatefulWidget {
  const JobVideoPreview({super.key, required this.url});

  final String url;

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
          height: 160,
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

// Owns only the ChewieController; JobVideoPreview owns the VideoPlayerController.
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
  );

  @override
  void dispose() {
    // Chewie's dispose leaves the shared controller playing behind the thumbnail.
    // Fire-and-forget; the platform channel keeps pause before seek.
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
