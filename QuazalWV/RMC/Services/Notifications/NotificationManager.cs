namespace QuazalWV
{
    public static class NotificationManager
    {
        /// <summary>
        /// Tells a client that a player has JOINED its session, using the
        /// Participation notification type.
        ///
        /// WHY THIS EXISTS. A private lobby will not launch below a minimum and
        /// says "not enough members in your group". Sending
        /// GameSession/InviteAccepted was tried and does nothing - the roster
        /// stayed empty and LAUNCH stayed grey - and the log shows why that was
        /// never likely: in a whole lobby session the client asks the server
        /// CreateSession, AddParticipants, RegisterURLs, UpdateSession and
        /// Abandon, and never once asks who is in the session. The roster is
        /// local state.
        ///
        /// Participation (type 3) is the one channel the enum defines for
        /// exactly this and that nothing in this codebase ever sends. If the
        /// client does not act on it either, no server-side message populates
        /// that roster and the gate is purely client-side.
        /// </summary>
        public static void ParticipationChanged(ClientInfo receiverClient, uint playerPid,
                                                uint sessionId, uint subtype)
        {
            new NotificationEvent(
                receiverClient,
                0,
                playerPid,
                (uint)NotificationEventType.Participation,
                subtype,
                playerPid,
                sessionId,
                0,
                ""
                ).Send();
        }

        /// <summary>
        /// Sends a friend/invite removal/denial notification.
        /// </summary>
        /// <param name="receiverClient"></param>
        /// <param name="senderPid"></param>
        /// <param name="senderName"></param>
        public static void FriendRemoved(ClientInfo receiverClient, uint senderPid, string senderName)
        {
            new NotificationEvent(
                receiverClient,
                0,
                senderPid,
                (uint)NotificationEventType.Friends,
                1,
                senderPid,
                (uint)FriendsNotificationParam2.FriendshipDeclined,
                0,
                senderName
                ).Send();
        }

        /// <summary>
        /// Sends a friend invite acceptance notification.
        /// </summary>
        /// <param name="receiverClient"></param>
        /// <param name="senderPid"></param>
        /// <param name="senderName"></param>
        public static void FriendInviteAccepted(ClientInfo receiverClient, uint senderPid, string senderName)
        {
            new NotificationEvent(
                receiverClient,
                0,
                senderPid,
                (uint)NotificationEventType.Friends,
                1,
                senderPid,
                (uint)FriendsNotificationParam2.FriendshipAccepted,
                0,
                senderName
                ).Send();
        }

        /// <summary>
        /// Sends a friend invite notification.
        /// <param name="receiverClient"></param>
        /// <param name="senderPid"></param>
        /// <param name="senderName"></param>
        /// </summary>
        public static void FriendInviteReceived(ClientInfo receiverClient, uint senderPid, string senderName)
        {
            new NotificationEvent(
                receiverClient,
                0,
                senderPid,
                (uint)NotificationEventType.Friends,
                1,
                senderPid,
                (uint)FriendsNotificationParam2.FriendshipRequested,
                0,
                senderName
                ).Send();
        }

        public static void FriendStatusChanged(ClientInfo receiverClient, uint senderPid, string senderName, bool online)
        {
            new NotificationEvent(
                receiverClient,
                0,
                senderPid,
                (uint)NotificationEventType.FriendStatusChange,
                1,
                senderPid,
                online ? 1u : 0u,
                0,
                senderName
                ).Send();
        }

        public static void GameInviteSent(ClientInfo receiverClient, uint senderPid, GameSessionInvitation invite)
        {
            new NotificationEvent(
                receiverClient,
                0,
                senderPid,
                (uint)NotificationEventType.GameSession,
                (uint)GameSessionNotificationSubtype.InviteReceived,
                0,
                invite.Key.SessionId,
                invite.Key.TypeId,
                invite.Message
                ).Send();
        }

        public static void GameInviteDeclined(ClientInfo receiverClient, uint senderPid, uint sessionId)
        {
            new NotificationEvent(
                receiverClient,
                0,
                senderPid,
                (uint)NotificationEventType.GameSession,
                (uint)GameSessionNotificationSubtype.InviteDeclined,
                0,
                sessionId,
                0,
                ""
                ).Send();
        }

        public static void GameInviteAccepted(ClientInfo receiverClient, uint senderPid, uint sessionId)
        {
            new NotificationEvent(
                receiverClient,
                0,
                senderPid,
                (uint)NotificationEventType.GameSession,
                (uint)GameSessionNotificationSubtype.InviteAccepted,
                0,
                sessionId,
                0,
                ""
                ).Send();
        }
    }
}
