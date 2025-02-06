SELECT _id as event_id, date as event_date, subject as event_title, category as event_type
FROM (SELECT * FROM EventNote en UNION SELECT * FROM Note n)
WHERE event_date BETWEEN ? AND ?



SELECT concat(en._id, e._id) as event_id, concat(en.date, e.date) as event_date
FROM EventNote en,
     Event,
     e
WHERE event_date BETWEEN ? AND ?



SELECT e._id as event_id, e.date as date, e.subject as event_title, e.category as event_type, json_extract(value, '$[0]') as participant_id, c.gender as participant_gender, c.identity as participant_identity, (strftime('%Y', 'now') - strftime('%Y', c.dateOfBirth)) - (strftime('%m-%d', 'now') < strftime('%m-%d', c.dateOfBirth)) as participant_age, c.area as participant_area, json_extract(value, '$[1].status') as status, json_extract(e.schools, '$[0]') as team_id, s.name as team_name, s.area as team_area, s.tier as team_tier
FROM EventNote e, json_each(e.childrenAttendance) JOIN Child as c
ON c._id = participant_id JOIN School as s ON s._id = team_id
WHERE e.date BETWEEN ? AND ?
