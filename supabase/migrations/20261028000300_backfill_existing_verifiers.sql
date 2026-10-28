begin;
update public.levels l
set verifier = p.gd_username
from (
  select distinct on (cs.level_id) cs.level_id, pr.gd_username
  from public.completion_submissions cs
  join public.profiles pr on pr.id = cs.submitter_id
  where cs.verification_submission_id is not null and cs.status = 'approved'
  order by cs.level_id, cs.created_at asc
) p
where l.id = p.level_id and l.verifier is null;
commit;
