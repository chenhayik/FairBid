import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/util/time_ago.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/user_avatar.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../home/presentation/home_app_bar.dart';
import '../data/chat_repository.dart';
import '../domain/conversation.dart';

/// The "Messages" tab: the user's conversations, most recently active first.
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

class _ConversationList extends StatelessWidget {
  const _ConversationList({required this.uid});
  final String uid;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Conversation>>(
      stream: context.read<ChatRepository>().watchConversations(uid),
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

/// One conversation: counterparty name, job title, last-message preview,
/// relative time and an unread-count pill.
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

    return InkWell(
      onTap: () => context.push('/messages/${conversation.id}'),
      borderRadius: BorderRadius.circular(12),
      child: AppCard(
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
      ),
    );
  }
}
