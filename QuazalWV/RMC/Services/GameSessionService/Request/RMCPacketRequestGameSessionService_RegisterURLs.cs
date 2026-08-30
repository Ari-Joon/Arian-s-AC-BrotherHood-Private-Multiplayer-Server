using System.Collections.Generic;
using System.IO;
using System.Text;

namespace QuazalWV
{
    public class RMCPacketRequestGameSessionService_RegisterURLs : RMCPRequest
    {
        public List<StationUrl> Urls {  get; set; }

        public RMCPacketRequestGameSessionService_RegisterURLs(Stream s)
        {
            Urls = new List<StationUrl>();
            uint count = Helper.ReadU32(s);
            for (uint i = 0; i < count; i++)
            {
                string b = Helper.ReadString(s);
                Urls.Add(new StationUrl(b));
                Log.WriteRmcLine(1, $"RegisterURLs - host URL: {b}", RMCP.PROTOCOL.GameSession, LogSource.RMC);
            }
        }

        public override string ToString()
        {
            return "[RegisterURLs Request]";
        }

        public override string PayloadToString()
        {
            var sb = new StringBuilder();
            foreach (StationUrl url in Urls)
                sb.Append($"\t[{url}]");
            return sb.ToString();
        }

        public override byte[] ToBuffer()
        {
            MemoryStream m = new MemoryStream();
            Helper.WriteU32(m, (uint)Urls.Count);
            foreach (StationUrl url in Urls)
                Helper.WriteString(m, url.ToString());
            return m.ToArray();
        }

        /// <summary>
        /// Record the caller's URLs. Only a HOST replaces the session's host
        /// URLs - those are the address every other client is told to connect
        /// to, so letting any participant overwrite them points the whole
        /// session at the wrong machine.
        /// </summary>
        public void RegisterUrls(ClientInfo client, Session ses, bool asHost = true)
        {
            client.RegisteredUrls.Clear();
            if (asHost)
                ses.HostUrls.Clear();
            foreach (StationUrl url in Urls)
            {
                client.RegisteredUrls.Add(url);
                if (asHost)
                    ses.HostUrls.Add(url);
            }
        }
    }
}
