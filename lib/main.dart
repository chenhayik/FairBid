import 'package:firebase_core/firebase_core.dart';
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
import 'features/jobs/data/bundle_bid_repository.dart';
import 'features/jobs/data/bundle_repository.dart';
import 'features/jobs/data/job_repository.dart';
import 'features/jobs/data/milestone_repository.dart';
import 'features/messages/data/chat_repository.dart';
import 'features/notifications/data/notification_repository.dart';
import 'features/notifications/data/push_service.dart';
import 'features/onboarding/data/document_storage_repository.dart';
import 'features/onboarding/data/onboarding_repository.dart';
import 'features/onboarding/data/requestor_onboarding_repository.dart';
import 'features/profile/data/public_profile_repository.dart';
import 'features/profile/data/review_repository.dart';
import 'features/profile/data/user_report_repository.dart';
import 'features/wallet/data/wallet_repository.dart';
import 'firebase_options.dart';

/// What:   App entry point.
/// Output: Initialises Firebase, then runs FairBidApp with the Firestore/Firebase-backed repositories.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(FairBidApp(
    authRepository: FirebaseAuthRepository(),
    onboardingRepository: FirestoreOnboardingRepository(),
    requestorOnboardingRepository: FirestoreRequestorOnboardingRepository(),
    documentStorageRepository: FirebaseDocumentStorageRepository(),
    jobRepository: FirestoreJobRepository(),
    bidRepository: FirestoreBidRepository(),
    bundleRepository: FirestoreBundleRepository(),
    bundleBidRepository: FirestoreBundleBidRepository(),
    reviewRepository: FirebaseReviewRepository(),
    publicProfileRepository: FirebasePublicProfileRepository(),
    userReportRepository: FirestoreUserReportRepository(),
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
