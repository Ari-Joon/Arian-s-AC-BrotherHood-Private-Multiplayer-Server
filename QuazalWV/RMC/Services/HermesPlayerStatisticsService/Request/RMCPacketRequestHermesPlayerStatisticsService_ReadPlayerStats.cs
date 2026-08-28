using System.Collections.Generic;
using System.IO;

namespace QuazalWV
{
	public class RMCPacketRequestHermesPlayerStatisticsService_ReadPlayerStats : RMCPRequest
	{
		public List<StatQuery> Queries { get; set; }
		public List<string> Players { get; set; }

		public RMCPacketRequestHermesPlayerStatisticsService_ReadPlayerStats(Stream s)
		{
			Queries = new List<StatQuery>();
			Players = new List<string>();

			uint count = Helper.ReadU32(s);
			for (uint i = 0; i < count; i++)
				Queries.Add(new StatQuery(s));
			count = Helper.ReadU32(s);
			for (uint i = 0; i < count; i++)
				Players.Add(Helper.ReadString(s));
		}

		public override string PayloadToString()
		{
			// Instrumented: dump exactly which stat IDs the client asks for, so we
			// can see what the challenge screen reads.
			System.Text.StringBuilder sb = new System.Text.StringBuilder();
			sb.AppendLine($"	[Players: {string.Join(", ", Players)}]");
			sb.AppendLine($"	[Queries: {Queries.Count}]");
			foreach (StatQuery q in Queries)
				sb.AppendLine($"		[StatId {q.StatId} -> InfoIds: {string.Join(",", q.InfoIds)}]");
			return sb.ToString();
		}

		public override byte[] ToBuffer()
		{
			MemoryStream m = new MemoryStream();
			Helper.WriteU32(m, (uint)Queries.Count);
			foreach (StatQuery query in Queries)
				query.ToBuffer(m);
			Helper.WriteU32(m, (uint)Players.Count);
			foreach (string player in Players)
				Helper.WriteString(m, player);
			return m.ToArray();
		}

		public override string ToString()
		{
			return "[ReadPlayerStats Request]";
		}
	}
}
