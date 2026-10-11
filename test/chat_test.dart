import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:fairbid/features/messages/domain/conversation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/builders.dart';
import 'helpers/fakes.dart';
import 'helpers/harness.dart';

void main() {
  group('Chat', () {
    Conversation sampleConversation() => Conversation(
      id: 'job-1_prov-1',
      jobId: 'job-1',
      jobTitle: 'Fix leaking sink',
      requestorId: 'uid-1',
      requestorName: 'Test User',
      providerId: 'prov-1',
      providerName: 'Pro Fixer',
      lastMessageAt: DateTime.now(),
    );

    test('Conversation helpers resolve the other party and unread count', () {
      final c = Conversation.fromMap('job-1_prov-1', {
        ...sampleConversation().toMap(),
        'lastMessageText': 'Hello!',
        'unreadCount': {'uid-1': 3},
      });
      expect(c.participantIds, ['uid-1', 'prov-1']);
      expect(c.otherPartyName('uid-1'), 'Pro Fixer');
      expect(c.otherPartyName('prov-1'), 'Test User');
      expect(c.unreadFor('uid-1'), 3);
      expect(c.unreadFor('prov-1'), 0);
      expect(c.lastMessageText, 'Hello!');
    });

    testWidgets('unread badge shows, opening the thread clears it, and a reply '
        'sends', (tester) async {

      final chat = FakeChatRepository([sampleConversation()]);
      // An incoming message from the provider → 1 unread for the requestor.
      await chat.sendMessage(
        conversation: sampleConversation(),
        senderId: 'prov-1',
        text: 'Hello! I can come by tomorrow.',
      );

      await pumpApp(tester, buildApp(FakeAuthRepository(), chat: chat), size: const Size(500, 1600));
      await logIn(tester);

      // The Messages tab shows the unread badge.
      expect(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );

      // The conversation list shows the counterparty, job and preview.
      await openTab(tester, 'Messages');
      expect(find.text('Pro Fixer'), findsOneWidget);
      expect(find.text('Fix leaking sink'), findsOneWidget);
      expect(find.text('Hello! I can come by tomorrow.'), findsOneWidget);

      // Open the thread → the message renders and unread clears.
      await tester.tap(find.text('Pro Fixer'));
      await tester.pumpAndSettle();
      expect(find.text('Hello! I can come by tomorrow.'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('1'),
        ),
        findsNothing,
      );

      // Send a reply.
      await tester.enterText(find.byType(TextField), 'Great, see you then!');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Great, see you then!'), findsOneWidget);
    });

    testWidgets('requestor opens the chat from the bottom bar', (
      tester,
    ) async {

      final chat = FakeChatRepository();
      final job = sampleJob(
        status: JobStatus.inProgress,
        acceptedProviderId: 'prov-1',
        acceptedProviderName: 'Pro Fixer',
        acceptedBidAmountSen: 15000,
      );
      await pumpApp(tester, buildApp(FakeAuthRepository(), jobs: [job], chat: chat), size: const Size(500, 1600));
      await logIn(tester);

      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();
      expect(find.text('Assigned provider'), findsOneWidget);

      // The bar's message button (the only one - the inline tile would
      // repeat it) lazily creates the conversation and opens it.
      expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'Message provider'));
      await tester.pumpAndSettle();
      expect(find.text('Start the conversation'), findsOneWidget);
      expect(find.text('Pro Fixer'), findsOneWidget); // thread app bar
    });
  });
}
