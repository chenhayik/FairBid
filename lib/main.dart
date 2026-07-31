import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import 'core/app.dart';
import 'features/admin/data/moderation_repository.dart';
import 'features/admin/data/stats_repository.dart';
import 'features/admin/data/user_admin_repository.dart';
import 'features/admin/data/verification_repository.dart';
import 'features/auth/data/auth_repository.dart';
import 'features/disputes/data/dispute_repository.dart';
import 'features/jobs/data/assist_repository.dart';
import 'features/jobs/data/bid_repository.dart';
import 'features/jobs/data/job_repository.dart';
import 'features/jobs/data/milestone_repository.dart';
import 'features/messages/data/chat_repository.dart';
import 'features/notifications/data/notification_repository.dart';
import 'features/notifications/data/push_service.dart';
import 'features/onboarding/data/document_storage_repository.dart';
import 'features/onboarding/data/onboarding_repository.dart';
import 'features/onboarding/data/requestor_onboarding_repository.dart';
import 'features/profile/data/review_repository.dart';
import 'features/wallet/data/wallet_repository.dart';
import 'firebase_options.dart';

/// FCM background handler. Must be a top-level `vm:entry-point` function —
/// it runs in its own isolate when a push arrives with the app terminated or
/// backgrounded. Android already displays notification-type messages itself;
/// this exists so the isolate has Firebase ready if data-only work is added.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  runApp(FairBidApp(
    authRepository: FirebaseAuthRepository(),
    onboardingRepository: FirestoreOnboardingRepository(),
    requestorOnboardingRepository: FirestoreRequestorOnboardingRepository(),
    documentStorageRepository: FirebaseDocumentStorageRepository(),
    jobRepository: FirestoreJobRepository(),
    bidRepository: FirestoreBidRepository(),
    reviewRepository: FirebaseReviewRepository(),
    verificationRepository: FirestoreVerificationRepository(),
    userAdminRepository: FirestoreUserAdminRepository(),
    chatRepository: FirestoreChatRepository(),
    milestoneRepository: FirestoreMilestoneRepository(),
    walletRepository: FirebaseWalletRepository(),
    disputeRepository: FirestoreDisputeRepository(),
    moderationRepository: FirestoreModerationRepository(),
    statsRepository: FirestoreStatsRepository(),
    notificationRepository: FirebaseNotificationRepository(),
    pushService: FirebasePushService(),
    assistRepository: FirebaseAssistRepository(),
  ));
}
