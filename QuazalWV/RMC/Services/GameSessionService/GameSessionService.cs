using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;

namespace QuazalWV
{
    public class GameSessionService
    {
        public const RMCP.PROTOCOL protocol = RMCP.PROTOCOL.GameSession;

        public static void ProcessRequest(Stream s, RMCP rmc, ClientInfo client)
        {
            switch (rmc.methodID)
            {
                case 1:
                    rmc.request = new RMCPacketRequestGameSessionService_CreateSession(s);
                    Log.WriteRmcLine(1, "CreateSession props:\n" + rmc.request.PayloadToString(), protocol, LogSource.RMC, Color.Blue, client);
                    break;
                case 2:
                    rmc.request = new RMCPacketRequestGameSessionService_UpdateSession(s);
                    Log.WriteRmcLine(1, "UpdateSession props:\n" + rmc.request.PayloadToString(), protocol, LogSource.RMC, Color.Purple, client);
                    break;
                case 4:
                    rmc.request = new RMCPacketRequestGameSessionService_MigrateSession(s);
                    break;
                case 5:
                    rmc.request = new RMCPacketRequestGameSessionService_LeaveSession(s);
                    break;
                case 6:
                    rmc.request = new RMCPacketRequestGameSessionService_GetSession(s);
                    break;
                case 7:
                    rmc.request = new RMCPacketRequestGameSessionService_SearchSessions(s);
                    Log.WriteRmcLine(1, "SearchSessions query props:\n" + rmc.request.PayloadToString(), protocol, LogSource.RMC, Color.Orange, client);
                    break;
                case 8:
                    rmc.request = new RMCPacketRequestGameSessionService_AddParticipants(s);
                    break;
                case 9:
                    rmc.request = new RMCPacketRequestGameSessionService_RemoveParticipants(s);
                    break;
                case 12:
                    rmc.request = new RMCPacketRequestGameSessionService_SendInvitation(s);
                    break;
                case 14:
                    rmc.request = new RMCPacketRequestGameSessionService_GetInvitationsReceived(s);
                    break;
                case 17:
                    rmc.request = new RMCPacketRequestGameSessionService_AcceptInvitation(s);
                    break;
                case 18:
                    rmc.request = new RMCPacketRequestGameSessionService_DeclineInvitation(s);
                    break;
                case 19:
                    rmc.request = new RMCPacketRequestGameSessionService_CancelInvitation(s);
                    break;
                case 21:
                    rmc.request = new RMCPacketRequestGameSessionService_RegisterURLs(s);
                    break;
                case 23:
                    rmc.request = new RMCPacketRequestGameSessionService_AbandonSession(s);
                    break;
                default:
                    Log.WriteRmcLine(1, $"Error: Unknown Method {rmc.methodID}", protocol, LogSource.RMC, Color.Red, client);
                    break;
            }
        }

        public static void HandleRequest(PrudpPacket p, RMCP rmc, ClientInfo client)
        {
            RMCPResponse reply;
            uint sesId;
            Property gameType, currPublicSlots, currPrivateSlots, accessibility;
            Session newSes, migrateFromSes;
            ClientInfo inviter;
            switch (rmc.methodID)
            {
                case 1:
                    var reqCreateSes = (RMCPacketRequestGameSessionService_CreateSession)rmc.request;
                    sesId = Global.NextGameSessionId++;
                    client.GameSessionID = sesId;
                    newSes = new Session(sesId, reqCreateSes.Session, client);
                    // initialize params
                    gameType = newSes.GameSession.Attributes.Find(param => param.Id == (uint)SessionParam.SessionType);
                    if (gameType == null)
                        Log.WriteLine(1, $"Inconsistent session state (id={newSes.Key.SessionId}), missing game type", LogSource.Session, Color.Red, client);
                    currPublicSlots = new Property() { Id = (uint)SessionParam.CurrentPublicSlots, Value = 0 };
                    currPrivateSlots = new Property() { Id = (uint)SessionParam.CurrentPrivateSlots, Value = 0 };
                    accessibility = new Property() { Id = (uint)SessionParam.Accessibility, Value = 0 };
                    newSes.GameSession.Attributes.Add(currPublicSlots);
                    newSes.GameSession.Attributes.Add(currPrivateSlots);
                    newSes.GameSession.Attributes.Add(accessibility);
                    // blind NAT type update
                    var natType = newSes.GameSession.Attributes.Find(param => param.Id == (uint)SessionParam.SessionNatType);
                    if (natType == null)
                        Log.WriteLine(1, $"Inconsistent session state (id={newSes.Key.SessionId}), missing NAT type", LogSource.Session, Color.Red, client);
                    natType.Value = (uint)NatType.OPEN;
                    Global.Sessions.Add(newSes);
                    reply = new RMCPacketResponseGameSessionService_CreateSession(reqCreateSes.Session.TypeId, sesId);
                    RMC.SendResponseWithACK(client.udp, p, rmc, client, reply);

                    // Pushing unsolicited join notifications here was tried and
                    // does nothing: the client never asks the server who is in a
                    // session, and INVITE FRIENDS showed every bot OFFLINE so it
                    // would not have invited them anyway. The working path is in
                    // SendInvitation - make the bot appear online, let the client
                    // invite it, then answer as a real client would.
                    break;
                case 2:
                    var reqUpdateSes = (RMCPacketRequestGameSessionService_UpdateSession)rmc.request;
                    newSes = Global.Sessions.Find(session => session.Key.SessionId == reqUpdateSes.SessionUpdate.Key.SessionId);
                    if (newSes == null)
                        Log.WriteRmcLine(1, $"Update for deleted session {reqUpdateSes.SessionUpdate.Key.SessionId}", protocol, LogSource.RMC, Color.Red, client);
                    foreach (var newParam in reqUpdateSes.SessionUpdate.Attributes)
                    {
                        var existing = newSes.GameSession.Attributes.FirstOrDefault(attr => attr.Id == newParam.Id);
                        if (existing != null)
                            existing.Value = newParam.Value;
                        else
                            newSes.GameSession.Attributes.Add(newParam);
                    }
                    reply = new RMCPResponseEmpty();
                    RMC.SendResponseWithACK(client.udp, p, rmc, client, reply);
                    break;
                case 4:
                    var reqMigrate = (RMCPacketRequestGameSessionService_MigrateSession)rmc.request;
                    try
                    {
                        Log.WriteRmcLine(1, $"Migrating from session {reqMigrate.Key.SessionId}", protocol, LogSource.RMC, Color.Blue, client);
                        migrateFromSes = Global.Sessions.Find(session => session.Key.SessionId == reqMigrate.Key.SessionId);
                        if (migrateFromSes == null)
                        {
                            Log.WriteRmcLine(1, $"Migrating session not found", protocol, LogSource.RMC, Color.Red, client);
                            reply = new RMCPResponseEmpty();
                            RMC.SendResponseWithACK(client.udp, p, rmc, client, reply, true, (uint)QError.GameSession_InvalidSessionKey);
                        }
                        else
                        {
                            migrateFromSes.Migrating = true;
                            reply = new RMCPacketResponseGameSessionService_MigrateSession(reqMigrate.Key);
                            RMC.SendResponseWithACK(client.udp, p, rmc, client, reply);
                        }
                    }
                    catch (Exception ex)
                    {
                        Log.WriteRmcLine(1, $"MigrateSession: {ex.Message}", protocol, LogSource.RMC, Color.Red, client);
                    }
                    break;
                case 5:
                    // does not change the session state
                    var reqLeaveSes = (RMCPacketRequestGameSessionService_LeaveSession)rmc.request;
                    reply = new RMCPResponseEmpty();
                    client.GameSessionID = 0;
                    client.InGameSession = false;
                    RMC.SendResponseWithACK(client.udp, p, rmc, client, reply);
                    break;
                case 6:
                    var reqGetSes = (RMCPacketRequestGameSessionService_GetSession)rmc.request;
                    newSes = Global.Sessions.Find(session => session.Key.SessionId == reqGetSes.Key.SessionId);
                    if (newSes == null)
                    {
                        Log.WriteRmcLine(1, $"Session {reqGetSes.Key.SessionId} not found", protocol, LogSource.RMC, Color.Red, client);
                        reply = new RMCPResponseEmpty();
                        RMC.SendResponseWithACK(client.udp, p, rmc, client, reply, true, (uint)QError.GameSession_InvalidSessionKey);
                    }
                    else if (newSes.IsJoinable())
                    {
                        ClientInfo host = Global.Clients.Find(c => c.User.Pid == newSes.HostPid);
                        if (host == null)
                        {
                            Log.WriteRmcLine(1, $"Session host {newSes.HostPid} not found", protocol, LogSource.RMC, Color.Red, client);
                            reply = new RMCPResponseEmpty();
                            RMC.SendResponseWithACK(client.udp, p, rmc, client, reply, true, (uint)QError.GameSession_InvalidPID);
                        }
                        else
                        {
                            reply = new RMCPacketResponseGameSessionService_GetSession(newSes, host);
                            Log.WriteRmcLine(1, $"Session {reqGetSes.Key.SessionId} found", protocol, LogSource.RMC, Color.Blue, client);
                            foreach (var url in ((RMCPacketResponseGameSessionService_GetSession)reply).SearchResult.HostUrls)
                                Log.WriteLine(1, $"[{url}]", LogSource.StationURL, Color.Blue, client);
                            RMC.SendResponseWithACK(client.udp, p, rmc, client, reply);
                        }
                    }
                    else
                    {
                        reply = new RMCPResponseEmpty();
                        var isPrivateSes = newSes.FindProp(SessionParam.IsPrivate);
                        if (isPrivateSes == null)
                        {
                            Log.WriteRmcLine(1, $"Session {reqGetSes.Key.SessionId} missing IsPrivate param", protocol, LogSource.RMC, Color.Red, client);
                            RMC.SendResponseWithACK(client.udp, p, rmc, client, reply, true, (uint)QError.GameSession_Unknown);
                        }
                        else
                        {
                            Log.WriteRmcLine(1, $"Session {reqGetSes.Key.SessionId} is full", protocol, LogSource.RMC, Color.Red, client);
                            QError error = isPrivateSes.Value == 0 ? QError.GameSession_NoPublicSlotLeft : QError.GameSession_NoPrivateSlotLeft;
                            RMC.SendResponseWithACK(client.udp, p, rmc, client, reply, true, (uint)error);
                        }
                    }
                    break;
                case 7:
                    var reqSearchSes = (RMCPacketRequestGameSessionService_SearchSessions)rmc.request;
                    Log.WriteRmcLine(2, $"SearchSessions query: {reqSearchSes.Query}", protocol, LogSource.RMC, Color.Green, client);
                    reply = new RMCPacketResponseGameSessionService_SearchSessions(reqSearchSes.Query, client);
                    Log.WriteRmcLine(2, $"SearchSessions results: {((RMCPacketResponseGameSessionService_SearchSessions)reply).Results.Count}", protocol, LogSource.RMC, Color.Green, client);
                    RMC.SendResponseWithACK(client.udp, p, rmc, client, reply);
                    break;
                case 8:
                    var reqAddParticip = (RMCPacketRequestGameSessionService_AddParticipants)rmc.request;
                    // update session
                    Global.Sessions.Find(session => session.Key.SessionId == reqAddParticip.Key.SessionId)
                        .AddParticipants(reqAddParticip.PublicPids, reqAddParticip.PrivatePids);
                    // update clients
                    foreach (uint pid in reqAddParticip.PublicPids)
                    {
                        ClientInfo result = Global.Clients.Find(c => c.User.Pid == pid);
                        if (result != null)
                        {
                            // Only a move BETWEEN sessions is an abandonment. Re-adding a
                            // player to the session they are already in must not mark them
                            // as abandoning it: AbandonSession (case 23) acts on
                            // AbandonedSessionID in preference to the requested session, so
                            // the flag would evict them from the live session on their next
                            // abandon and could delete it once empty.
                            if (result.InGameSession == true && result.GameSessionID != reqAddParticip.Key.SessionId)
                            {
                                Log.WriteRmcLine(1, $"{result.User.Name} moving from session {result.GameSessionID} to {reqAddParticip.Key.SessionId} on AddParticipants", protocol, LogSource.RMC, Color.Orange, client);
                                result.AbandoningSession = true;
                                result.AbandonedSessionID = result.GameSessionID;
                            }
                            result.GameSessionID = reqAddParticip.Key.SessionId;
                            result.InGameSession = true;
                        }
                        else
                            Log.WriteRmcLine(1, $"AddParticipants: player {pid} is not online", protocol, LogSource.RMC, Color.Red, client);
                    }

                    foreach (uint pid in reqAddParticip.PrivatePids)
                    {
                        ClientInfo result = Global.Clients.Find(c => c.User.Pid == pid);
                        if (result != null)
                        {
                            // Only a move BETWEEN sessions is an abandonment. Re-adding a
                            // player to the session they are already in must not mark them
                            // as abandoning it: AbandonSession (case 23) acts on
                            // AbandonedSessionID in preference to the requested session, so
                            // the flag would evict them from the live session on their next
                            // abandon and could delete it once empty.
                            if (result.InGameSession == true && result.GameSessionID != reqAddParticip.Key.SessionId)
                            {
                                Log.WriteRmcLine(1, $"{result.User.Name} moving from session {result.GameSessionID} to {reqAddParticip.Key.SessionId} on AddParticipants", protocol, LogSource.RMC, Color.Orange, client);
                                result.AbandoningSession = true;
                                result.AbandonedSessionID = result.GameSessionID;
                            }
                            result.GameSessionID = reqAddParticip.Key.SessionId;
                            result.InGameSession = true;
                        }
                        else
                            Log.WriteRmcLine(1, $"AddParticipants: player {pid} is not online", protocol, LogSource.RMC, Color.Red, client);
                    }
                    reply = new RMCPResponseEmpty();
                    RMC.SendResponseWithACK(client.udp, p, rmc, client, reply);
                    break;
                case 9:
                    var reqRemoveParticip = (RMCPacketRequestGameSessionService_RemoveParticipants)rmc.request;
                    Global.Sessions.Find(session => session.Key.SessionId == reqRemoveParticip.Key.SessionId)
                        .RemoveParticipants(reqRemoveParticip.Pids);
                    reply = new RMCPResponseEmpty();
                    RMC.SendResponseWithACK(client.udp, p, rmc, client, reply);
                    break;
                case 12:
                    var reqSendInvitation = (RMCPacketRequestGameSessionService_SendInvitation)rmc.request;
                    Log.WriteRmcLine(1, $"SendInvitation:\n{reqSendInvitation.Invitation}", protocol, LogSource.RMC, Color.Blue, client);
                    ClientInfo invitee;
                    foreach (uint pid in reqSendInvitation.Invitation.Recipients)
                    {
                        invitee = Global.Clients.Find(c => c.User.Pid == pid);
                        // Store the invitation ALWAYS, not only when the invitee is
                        // offline. GetInvitationsReceived (case 14) reads from the
                        // database, and the client calls it when it looks for its
                        // invites - so a CONNECTED invitee that received only a
                        // notification has nothing to accept. Observed exactly that
                        // with a second client on one machine: it asked for its
                        // invites, the table was empty, and it created its own lobby
                        // instead of joining the one it was invited to.
                        DbHelper.AddGameInvites(reqSendInvitation.Invitation.Key, client.User.Pid, pid,
                                                reqSendInvitation.Invitation.Message);
                        if (invitee != null)
                            NotificationManager.GameInviteSent(invitee, client.User.Pid, reqSendInvitation.Invitation);
                        else if (Global.IsStandInBot(pid))
                        {
                            // Answer exactly as a real bot client would: join the
                            // session, then tell the inviter it accepted. This time
                            // the client SENT the invite, so it has local state
                            // expecting this player - unlike the earlier attempt,
                            // which pushed an accept for an invite that never
                            // happened and was ignored.
                            var ses = Global.Sessions.Find(x => x.Key.SessionId == reqSendInvitation.Invitation.Key.SessionId);
                            if (ses != null)
                            {
                                var isPriv = ses.FindProp(SessionParam.IsPrivate);
                                if (isPriv != null && isPriv.Value != 0)
                                    ses.AddParticipants(new List<uint>(), new List<uint> { pid });
                                else
                                    ses.AddParticipants(new List<uint> { pid }, new List<uint>());
                                Log.WriteLine(1, $"Stand-in bot {pid} joined session {ses.Key.SessionId} " +
                                                 $"({ses.NbParticipants()} participants)", LogSource.Session, Color.Orange);
                            }
                            NotificationManager.GameInviteAccepted(client, pid, reqSendInvitation.Invitation.Key.SessionId);
                            // GameInviteAccepted alone left the roster empty, and the
                            // log shows the client never asks the server who is in a
                            // session - the roster is local state. Participation is the
                            // one notification channel defined for a player joining that
                            // this server has never sent, so fire it too.
                            foreach (uint sub in Global.ParticipationSubtypes)
                                NotificationManager.ParticipationChanged(
                                    client, pid, reqSendInvitation.Invitation.Key.SessionId, sub);
                        }
                    }
                    reply = new RMCPResponseEmpty();
                    RMC.SendResponseWithACK(client.udp, p, rmc, client, reply);
                    break;
                case 14:
                    var reqGetInvRecv = (RMCPacketRequestGameSessionService_GetInvitationsReceived)rmc.request;
                    var respGetInvRecv = new RMCPacketResponseGameSessionService_GetInvitationsReceived();
                    // Invitations stored for this player while they were offline.
                    // Note these are also pushed as notifications at logon by
                    // FriendsService.SendLogonGameInvites, which deletes them once
                    // delivered - so this list is normally empty for a client that
                    // has already completed logon.
                    foreach (var storedInvite in DbHelper.GetGameInvites(client.User.Pid))
                    {
                        if (storedInvite.Invitation == null || storedInvite.Invitation.Key == null)
                            continue;
                        if (reqGetInvRecv.GameSessionTypeId != 0 &&
                            storedInvite.Invitation.Key.TypeId != reqGetInvRecv.GameSessionTypeId)
                            continue;
                        respGetInvRecv.Invitations.Add(new GameSessionInvitationReceived
                        {
                            SessionKey = storedInvite.Invitation.Key,
                            SenderPid = storedInvite.Inviter,
                            Message = storedInvite.Invitation.Message,
                            // game_invites carries no timestamp column, so the
                            // creation time is approximated at read time.
                            CreationTime = new QDateTime(DateTime.Now)
                        });
                        if (reqGetInvRecv.ResultRange.Size > 0 &&
                            respGetInvRecv.Invitations.Count >= reqGetInvRecv.ResultRange.Size)
                            break;
                    }
                    Log.WriteRmcLine(1, $"GetInvitationsReceived: returning {respGetInvRecv.Invitations.Count} invite(s)", protocol, LogSource.RMC, Color.Blue, client);
                    reply = respGetInvRecv;
                    RMC.SendResponseWithACK(client.udp, p, rmc, client, reply);
                    break;
                case 17:
                    var reqAcceptInvite = (RMCPacketRequestGameSessionService_AcceptInvitation)rmc.request;
                    reply = new RMCPResponseEmpty();
                    RMC.SendResponseWithACK(client.udp, p, rmc, client, reply);

                    // The invite has been answered, so drop it from the store.
                    // Invites are now written for connected clients too, and
                    // without this they would be replayed at the next logon and
                    // point at a session that has long since ended.
                    DbHelper.DeleteGameInvites(client.User.Pid);

                    // Join the accepting player to the host's session.
                    //
                    // Without this the server acknowledged the acceptance and told the
                    // host about it, but never made the player a participant. The host's
                    // lobby listed them (it acts on the notification below) while the
                    // server still reported IsInSession=no for them, the session's slot
                    // count never rose, and the match sat on its loading screen counting
                    // one player. AddParticipants (case 8) has always done this properly;
                    // accepting an invitation did not.
                    uint acceptedSesId = reqAcceptInvite.InvitationRecv.SessionKey.SessionId;
                    var acceptedSes = Global.Sessions.Find(ses => ses.Key.SessionId == acceptedSesId);
                    if (acceptedSes == null)
                        Log.WriteRmcLine(1, $"AcceptInvitation: session {acceptedSesId} not found", protocol, LogSource.RMC, Color.Red, client);
                    else if (acceptedSes.PublicPids.Contains(client.User.Pid) || acceptedSes.PrivatePids.Contains(client.User.Pid))
                        Log.WriteRmcLine(1, $"{client.User.Name} already a participant of session {acceptedSesId}", protocol, LogSource.RMC, Color.Orange, client);
                    else
                    {
                        // Mirror case 8: if they were in another session, mark it abandoned.
                        if (client.InGameSession && client.GameSessionID != acceptedSesId)
                        {
                            client.AbandoningSession = true;
                            client.AbandonedSessionID = client.GameSessionID;
                        }
                        var sesType = acceptedSes.GameSession.Attributes.Find(pr => pr.Id == (uint)SessionParam.SessionType);
                        bool joinPrivate = sesType != null && sesType.Value == (uint)SessionType.PRIVATE;
                        var joiner = new List<uint> { client.User.Pid };
                        var empty = new List<uint>();
                        acceptedSes.AddParticipants(joinPrivate ? empty : joiner, joinPrivate ? joiner : empty);
                        client.GameSessionID = acceptedSesId;
                        client.InGameSession = true;
                        Log.WriteRmcLine(1, $"{client.User.Name} joined session {acceptedSesId} on invite accept ({(joinPrivate ? "private" : "public")} slot)", protocol, LogSource.RMC, Color.Green, client);
                    }

                    // invite accepted notif
                    inviter = Global.Clients.Find(c => c.User.Pid == reqAcceptInvite.InvitationRecv.SenderPid);
                    if (inviter != null)
                        NotificationManager.GameInviteAccepted(inviter, client.User.Pid, reqAcceptInvite.InvitationRecv.SessionKey.SessionId);
                    break;
                case 18:
                    var reqDeclineInvite = (RMCPacketRequestGameSessionService_DeclineInvitation)rmc.request;
                    // The invite has been answered, so drop it from the store.
                    // Invites are now written for connected clients too, and
                    // without this they would be replayed at the next logon and
                    // point at a session that has long since ended.
                    DbHelper.DeleteGameInvites(client.User.Pid);
                    reply = new RMCPResponseEmpty();
                    RMC.SendResponseWithACK(client.udp, p, rmc, client, reply);
                    // invite declined notif
                    inviter = Global.Clients.Find(c => c.User.Pid == reqDeclineInvite.InvitationRecv.SenderPid);
                    if (inviter != null)
                        NotificationManager.GameInviteDeclined(inviter, client.User.Pid, reqDeclineInvite.InvitationRecv.SessionKey.SessionId);
                    break;
                case 19:
                    reply = new RMCPResponseEmpty();
                    RMC.SendResponseWithACK(client.udp, p, rmc, client, reply);
                    break;
                case 21:
                    var reqRegUrls = (RMCPacketRequestGameSessionService_RegisterURLs)rmc.request;
                    reply = new RMCPResponseEmpty();
                    if (client.GameSessionID == 0)
                    {
                        Log.WriteRmcLine(1, $"RegisterURLs: {client.User.Name} is not in a session", protocol, LogSource.RMC, Color.Red, client);
                        RMC.SendResponseWithACK(client.udp, p, rmc, client, reply, true, (uint)QError.GameSession_PlayerIsNotSessionParticipant);
                    }
                    else
                    {
                        var ses = Global.Sessions.Find(s => s.Key.SessionId == client.GameSessionID);
                        if (ses == null)
                        {
                            Log.WriteRmcLine(1, $"RegisterURLs: session {client.GameSessionID} was deleted", protocol, LogSource.RMC, Color.Red, client);
                            RMC.SendResponseWithACK(client.udp, p, rmc, client, reply, true, (uint)QError.GameSession_Unknown);
                        }
                        else
                        {
                            var newHostPid = reqRegUrls.Urls.First().PID;
                            ses.HostPid = newHostPid;
                            reqRegUrls.RegisterUrls(client, ses);
                            if (ses.Migrating)
                            {
                                Log.WriteRmcLine(1, $"RegisterURLs: Host migration for session {ses.Key.SessionId}, new host {newHostPid}", protocol, LogSource.RMC, Color.Blue, client);
                                ses.Migrating = false;
                            }
                            RMC.SendResponseWithACK(client.udp, p, rmc, client, reply);
                        }
                    }
                    break;
                case 23:
                    var reqAbandon = (RMCPacketRequestGameSessionService_AbandonSession)rmc.request;
                    Session abandonedSes;
                    if (client.AbandoningSession == true)
                    {
                        client.AbandoningSession = false;
                        abandonedSes = Global.Sessions.Find(session => session.Key.SessionId == client.AbandonedSessionID);
                    }
                    else
                        abandonedSes = Global.Sessions.Find(session => session.Key.SessionId == reqAbandon.Key.SessionId);
                    if (abandonedSes != null)
                    {
                        client.GameSessionID = 0;
                        client.InGameSession = false;
                        bool removed = false;
                        if (abandonedSes.PublicPids.Contains(client.User.Pid))
                            removed = abandonedSes.PublicPids.Remove(client.User.Pid);

                        if (abandonedSes.PrivatePids.Contains(client.User.Pid))
                        {
                            bool privRemoved = abandonedSes.PrivatePids.Remove(client.User.Pid);
                            removed = removed ? removed : privRemoved;
                        }
                        
                        if (abandonedSes.NbParticipants() == 0)
                        {
                            // duplicate request check
                            if (removed)
                            {
                                Global.Sessions.Remove(abandonedSes);
                                Log.WriteRmcLine(1, $"Session {abandonedSes.Key.SessionId} deleted on abandon from player {client.User.Pid}", protocol, LogSource.RMC, Color.Gray, client);
                            }
                            else
                                Log.WriteRmcLine(1, $"AbandonSession request duplicate", protocol, LogSource.RMC, Color.Gray, client);
                        }
                    }
                    else
                        Log.WriteRmcLine(1, $"AbandonSession: session {reqAbandon.Key.SessionId} not found", protocol, LogSource.RMC, Color.Red, client);
                    reply = new RMCPResponseEmpty();
                    RMC.SendResponseWithACK(client.udp, p, rmc, client, reply);
                    break;
                default:
                    Log.WriteRmcLine(1, $"Error: Unknown Method {rmc.methodID}", protocol, LogSource.RMC, Color.Red, client);
                    break;
            }
        }
    }
}
