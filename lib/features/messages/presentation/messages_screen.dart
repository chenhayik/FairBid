import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/util/time_ago.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/keyed_stream_builder.dart';
import '../../../core/widgets/user_avatar.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../home/presentation/home_app_bar.dart';
import '../data/chat_repository.dart';
import '../domain/conversation.dart';

/// What:   The Messages tab: the user's conversations, most recently active first.
/// Input:  ChatRepository.watchConversations(uid) (chat_repository.dart).
/// Output: Tiles that open `/messages/{id}`, or an empty state.
class MessagesScreen extends StatelessWidget {
  const MessagesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = context.watch<AuthController>().user;
    return Scaffold(
      appBar: const HomeAppBar(),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: Text('Messages', style: theme.textTheme.headlineMedium),
            ),
            Expanded(
              child: user == null
                  ? const _NoConversations()
                  : _ConversationList(uid: user.uid),
            ),
          ],
        ),
      ),
    );
  }
}

/// What:   The signed-in user's conversations.
/// Input:  [uid]; ChatRepository.watchConversations(uid) (chat_repository.dart).
/// Output: Tiles separated by gaps, or loading, error and empty states.
class _ConversationList extends StatelessWidget {
  const _ConversationList({required this.uid});
  final String uid;

  @override
  Widget build(BuildContext context) {
    return KeyedStreamBuilder<List<Conversation>>(
      cacheKey: uid,
      create: () => context.read<ChatRepository>().watchConversations(uid),
      builder: (context, snapshot) {
        if (!snapshot.hasData && !snapshot.hasError) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return const EmptyState(
            icon: Icons.error_outline,
            title: 'Could not load messages',
            message: 'Please check your connection and try again.',
          );
        }
        final conversations = snapshot.data ?? [];
        if (conversations.isEmpty) return const _NoConversations();
        return ListView.separated(
          padding: const EdgeInsets.all(24),
          itemCount: conversations.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, i) =>
              _ConversationTile(conversation: conversations[i], myUid: uid),
        );
      },
    );
  }
}

/// What:   Empty state for a user with no conversations.
/// Input:  None.
/// Output: "No messages yet" with the hint that chat opens once a bid is accepted.
class _NoConversations extends StatelessWidget {
  const _NoConversations();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.forum_outlined,
      title: 'No messages yet',
      message: 'Once a bid is accepted, you can chat with the other party '
          'here.',
    );
  }
}

/// What:   One conversation row: counterparty, job title, preview, time and unread pill.
/// Input:  [conversation]; [myUid] picks the other party and the unread count.
/// Output: AppCard opening `/messages/{id}`; the preview is bold when there are unread messages.
class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.conversation, required this.myUid});
  final Conversation conversation;
  final String myUid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unread = conversation.unreadFor(myUid);
    final preview = conversation.lastMessageText.isEmpty
        ? 'No messages yet'
        : conversation.lastMessageText;

    return AppCard(
        onTap: () => context.push('/messages/${conversation.id}'),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            UserAvatar(photoUrl: conversation.otherPartyPhotoUrl(myUid)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          conversation.otherPartyName(myUid),
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge,
                        ),
                      ),
                      Text(
                        timeAgo(conversation.lastMessageAt),
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                  Text(
                    conversation.jobTitle,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium
                        ?.copyWith(color: context.fairbid.verified),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: unread > 0 ? FontWeight.w600 : null,
                          ),
                        ),
                      ),
                      if (unread > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: context.fairbid.verified,
                            borderRadius: BorderRadius.circular(9999),
                          ),
                          child: Text('$unread',
                              style: theme.textTheme.labelMedium
                                  ?.copyWith(color: Colors.white)),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      );
  }
}
