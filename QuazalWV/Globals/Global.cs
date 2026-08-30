using System;
using System.Collections.Generic;
using System.Linq;
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

        /// <summary>
        /// Bot accounts start at this PID in the seeded database.
        /// </summary>
        public const uint FirstBotPid = 1003;

        /// <summary>
        /// True if this PID is one of the stand-in bots the server pretends is
        /// online. The INVITE FRIENDS screen lists every bot as OFFLINE because
        /// FriendsService decides online-ness by whether a client is connected,
        /// and an offline friend cannot be invited - which is why fabricating
        /// join notifications achieved nothing. The client has to be able to
        /// send the invite itself.
        ///
        /// Deliberately NOT tied to FakePartyMembers: that controls how many
        /// slots the server pads a session to, which is a different question
        /// from whether a given PID is a bot account. Tying them together left
        /// Bot6-Bot8 permanently offline whenever the pad was set below 8.
        /// </summary>
        /// <summary>
        /// How many bot accounts the seeded database holds (Bot1..Bot8).
        /// </summary>
        public const uint BotCount = 8;

        /// <summary>
        /// Which Participation notification subtypes to fire when a stand-in bot
        /// joins. The enum names them Notif1/2/3/8 without saying what they mean,
        /// and nothing in this codebase ever sent one, so which (if any) the client
        /// acts on is unknown. Kept in config so the set can be narrowed by editing
        /// ACBRDV.exe.config and restarting, rather than rebuilding per guess.
        /// Empty disables Participation entirely.
        /// </summary>
        public static uint[] ParticipationSubtypes { get; set; } =
            (ConfigurationManager.AppSettings["ParticipationSubtypes"] ?? "1,2,3,8")
                .Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries)
                .Select(x => x.Trim())
                .Where(x => uint.TryParse(x, out _))
                .Select(uint.Parse)
                .ToArray();

        public static bool IsStandInBot(uint pid) =>
            pid >= FirstBotPid && pid < FirstBotPid + BotCount;

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
