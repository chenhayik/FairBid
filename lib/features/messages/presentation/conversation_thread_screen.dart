import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/util/time_ago.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/user_chip.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/chat_repository.dart';
import '../domain/conversation.dart';
import '../domain/message.dart';

/// What:   One chat thread: message history (newest at the bottom) and a composer.
/// Input:  [conversationId]; ChatRepository.watchConversation()/watchMessages() (chat_repository.dart).
/// Output: Thread UI; send calls sendMessage, and opening clears the viewer's unread counter.
class ConversationThreadScreen extends StatefulWidget {
  const ConversationThreadScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  State<ConversationThreadScreen> createState() =>
      _ConversationThreadScreenState();
}

class _ConversationThreadScreenState extends State<ConversationThreadScreen> {
  final _composer = TextEditingController();
  bool _sending = false;

  // Created once so rebuilds don't resubscribe.
  late final Stream<Conversation?> _conversation;
  late final Stream<List<Message>> _messages;

  @override
  void initState() {
    super.initState();
    final repo = context.read<ChatRepository>();
    _conversation = repo.watchConversation(widget.conversationId);
    _messages = repo.watchMessages(widget.conversationId);
  }

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  Future<void> _send(Conversation conversation, String myUid) async {
    final text = _composer.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await context.read<ChatRepository>().sendMessage(
          conversation: conversation, senderId: myUid, text: text);
      _composer.clear();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not send the message. Please try again.')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final myUid = context.watch<AuthController>().user?.uid;

    return StreamBuilder<Conversation?>(
      stream: _conversation,
      builder: (context, snapshot) {
        final conversation = snapshot.data;

        // Clears my unread counter; the next snapshot has zero, so this converges.
        if (conversation != null &&
            myUid != null &&
            conversation.unreadFor(myUid) > 0) {
          final repo = context.read<ChatRepository>();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            // A failed clear just leaves the badge until the next open.
            repo
                .markRead(widget.conversationId, myUid)
                .catchError((_) {});
          });
        }

        return Scaffold(
          appBar: AppBar(
            toolbarHeight: 72,
            // Tapping the header opens the counterparty's public profile.
            title: conversation == null || myUid == null
                ? const Text('Chat')
                : UserChip(
                    uid: conversation.otherPartyId(myUid),
                    name: conversation.otherPartyName(myUid),
                    photoUrl: conversation.otherPartyPhotoUrl(myUid),
                    subtitle: conversation.jobTitle,
                    avatarRadius: 18,
                    showChevron: false,
                  ),
          ),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(child: _MessageList(stream: _messages, myUid: myUid)),
                // A stream error leaves `conversation` null for good, so say so
                // instead of showing a dead composer.
                if (snapshot.hasError)
                  const _Footer(
                    icon: Icons.cloud_off,
                    text: "Couldn't load this conversation. Check your "
                        'connection, then go back and open it again.',
                    error: true,
                  )
                else if (conversation != null &&
                    !conversation.isOpenAt(DateTime.now()))
                  const _Footer(
                    icon: Icons.lock_outline,
                    text: 'This conversation is closed. You can still read '
                        'the history.',
                  )
                else
                  _Composer(
                    controller: _composer,
                    sending: _sending,
                    onSend: conversation == null || myUid == null
                        ? null
                        : () => _send(conversation, myUid),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MessageList extends StatelessWidget {
  const _MessageList({required this.stream, required this.myUid});
  final Stream<List<Message>> stream;
  final String? myUid;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Message>>(
      stream: stream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return const EmptyState(
            icon: Icons.error_outline,
            title: 'Could not load messages',
            message: 'Please check your connection and try again.',
          );
        }
        final messages = snapshot.data ?? [];
        if (messages.isEmpty) {
          return const EmptyState(
            icon: Icons.waving_hand_outlined,
            title: 'Start the conversation',
            message: 'Say hello and confirm the job details.',
          );
        }
        // Newest-first data in a reversed list puts the newest at the bottom.
        return ListView.builder(
          reverse: true,
          padding: const EdgeInsets.all(16),
          itemCount: messages.length,
          itemBuilder: (context, i) => _MessageBubble(
            message: messages[i],
            isMine: messages[i].senderId == myUid,
          ),
        );
      },
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.isMine});
  final Message message;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brand = context.fairbid.verified;
    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.75),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isMine ? brand : Colors.white,
          border: isMine
              ? null
              : Border.all(color: context.fairbid.borderSubtle),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(12),
            topRight: const Radius.circular(12),
            bottomLeft: Radius.circular(isMine ? 12 : 2),
            bottomRight: Radius.circular(isMine ? 2 : 12),
          ),
        ),
        child: Column(
          crossAxisAlignment:
              isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              message.text,
              style: theme.textTheme.bodyLarge?.copyWith(
                  color: isMine ? Colors.white : theme.colorScheme.onSurface),
            ),
            const SizedBox(height: 2),
            Text(
              timeAgo(message.createdAt),
              style: theme.textTheme.bodySmall?.copyWith(
                color: isMine
                    ? Colors.white.withValues(alpha: 0.9)
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Replaces the composer with an icon and message (stream failed, or chat closed); [error] tints the icon.
class _Footer extends StatelessWidget {
  const _Footer({required this.icon, required this.text, this.error = false});

  final IconData icon;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: context.fairbid.borderSubtle)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon,
              size: 18,
              color: error
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;

  /// Null while the conversation or user isn't loaded; disables the field.
  final VoidCallback? onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: context.fairbid.borderSubtle)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: onSend != null && !sending,
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Type a message…',
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              onSubmitted: (_) => onSend?.call(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            tooltip: 'Send',
            onPressed: sending ? null : onSend,
            icon: sending
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.send_rounded),
          ),
        ],
      ),
    );
  }
}
