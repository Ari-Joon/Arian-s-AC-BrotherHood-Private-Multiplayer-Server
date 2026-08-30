using System.Collections.Generic;
using System.Net;
using System.Configuration;
using System.Drawing;

namespace QuazalWV
{
    public static class Global
    {
        public const string Rc4KeyRdv = "CD&ML";
        public static readonly byte[] Rc4KeyP2p = Helper.P2pKey();
        public static string ServerBindAddress { get; set; } = ConfigurationManager.AppSettings["SecureServerAddress"];
        /// <summary>
        /// Pad the participant count reported for a session up to this
        /// value, so a lobby with one real player looks fuller than it is.
        ///
        /// WHY THIS EXISTS. A private match will not start below a minimum
        /// number of players, which makes every map except the scripted
        /// introductory session unreachable alone - you cannot look at eleven
        /// of the twelve maps without five other people. The client is known to
        /// trust the server's account of a session over its own: a fixed invite
        /// bug once had the host's lobby listing a player the server did not
        /// actually have, because the display follows the message.
        ///
        /// This is a LIE TOLD TO THE CLIENT and nothing more. No participant is
        /// created, no slot is reserved, and IsJoinable still compares against
        /// MaxPrivateSlots (8), so real players can still join. If the launch
        /// gate turns out to live in the client's own participant list rather
        /// than this number, the setting will simply do nothing - which is the
        /// experiment it exists to run.
        ///
        /// 0 disables it. Set it in App.config.
        /// </summary>
        public static uint MinReportedSlots { get; set; } =
            uint.TryParse(ConfigurationManager.AppSettings["MinReportedSlots"], out var v) ? v : 0;

        /// <summary>
        /// Fabricate this many party members when a session is created, by
        /// sending the host GameSession/InviteAccepted notifications carrying
        /// bot PIDs.
        ///
        /// WHY THIS AND NOT SLOT PADDING. A private lobby refuses to launch
        /// below a minimum, and the client says why: "not enough members in
        /// your GROUP". Padding CurrentPrivateSlots was tried and provably did
        /// nothing - the gate reads the party roster, not the session slots.
        /// The roster is populated by notifications: an invite-accepted
        /// notification once made the host's lobby list a player the server did
        /// not actually have, because the lobby acts on the message. This sends
        /// that message deliberately.
        ///
        /// The PIDs used are real Bot accounts from the database, so the client
        /// can resolve names for them rather than showing blanks.
        ///
        /// 0 disables it. Set in App.config.
        /// </summary>
        public static uint FakePartyMembers { get; set; } =
            uint.TryParse(ConfigurationManager.AppSettings["FakePartyMembers"], out var fp) ? fp : 0;

        public static uint IdCounter { get; set; } = 0x12345678;
        public static uint PidCounter { get; set; } = 0x1234;
        public static uint GathIdCounter { get; set; } = 0x34;
        public static List<ClientInfo> Clients { get; set; } = new List<ClientInfo>();
        public static uint NextGameSessionId { get; set; } = 1;
        public static List<Session> Sessions { get; set; } = new List<Session>();

        public static ClientInfo GetClientByEndPoint(IPEndPoint ep)
        {
            foreach (ClientInfo c in Clients)
                if (c.ep.Address.ToString() == ep.Address.ToString() && c.ep.Port == ep.Port)
                    return c;
            WriteLog(2, $"Cant find client for endpoint: {ep}");
            return null;
        }

        public static ClientInfo GetClientByIDrecv(uint id)
        {
            foreach (ClientInfo c in Clients)
                if (c.IDrecv == id)
                    return c;
            WriteLog(2, "Cant find client for id : 0x" + id.ToString("X8"));
            return null;
        }

        private static void WriteLog(int priority, string content)
        {
            Log.WriteLine(priority, content, LogSource.Global, Color.Orange);
        }

        internal static void RemoveSessionsOnLogin(ClientInfo client)
        {
            client.RegisteredUrls.Clear();
            client.Urls.Clear();
            Sessions.RemoveAll(s => s.HostPid == client.User.Pid);
        }
    }
}
