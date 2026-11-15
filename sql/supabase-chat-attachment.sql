-- =====================================================================
-- Crowd Test Tracker — "📎 Attach file" in chat (Supabase Storage)
-- Paste into Supabase → SQL Editor → Run. Safe to re-run.
--
-- Reported: a tester had no way to attach a file to the Applause chat (cycle-wide or
-- per-transaction) and had to send it via Slack instead. This bucket lets a file picked
-- from the compose box be uploaded and shared via a public link, attached to the next
-- message sent — same pattern as tx-videos / cycle-testplans above.
--
-- MVP policy, same spirit as the rest of this project: anon (every connected browser)
-- can upload, read and delete — tighten later if needed, the same way the main
-- crowd_tracker table is documented as open-for-now.
-- =====================================================================

insert into storage.buckets (id, name, public, file_size_limit)
values ('chat-attachments', 'chat-attachments', true, 104857600)   -- public bucket, 100MB per file cap
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit;

drop policy if exists "chat-attachments anon upload" on storage.objects;
create policy "chat-attachments anon upload" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'chat-attachments');

drop policy if exists "chat-attachments anon read" on storage.objects;
create policy "chat-attachments anon read" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'chat-attachments');

drop policy if exists "chat-attachments anon delete" on storage.objects;
create policy "chat-attachments anon delete" on storage.objects
  for delete to anon, authenticated
  using (bucket_id = 'chat-attachments');

-- Housekeeping (optional, e.g. monthly) — list/delete old files no message references anymore:
-- select name, created_at, metadata->>'size' as bytes from storage.objects where bucket_id = 'chat-attachments' order by created_at;
