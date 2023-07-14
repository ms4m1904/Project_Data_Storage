use SRD_upgrade_db;

#EXERCISES 

# General commments on optimization (detailed ones after each query):
# The data types are as simple as possible and native to the data they store.
# The types that require a size are also adjusted to be as small as possible for better performance.
# We avoided using SELECT * and selected specific fields instead.
# We avoided using SELECT DISTINCT.
# We defined filters with WHERE and not HAVING and most of our WHERE clauses use variables that are defined as indexes.

#1.
# Listing every session that took place in 2022
# explain
select s.student_name, 
	ss.session_id, 
    t.tutor_name, 
    c.course_name, 
    ss.school_year_id as 'School Year', 
    ss.start_time, 
    ss.end_time 
from students s
join sessions ss on ss.student_id = s.student_id
join tutors t on ss.tutor_id = t.tutor_id
join courses c on ss.course_id = c.course_id
where ss.status = "done"
and (start_time BETWEEN '2022-01-01 14:00:00' AND now());

# In this query, we ran the explain command and it ended up showing that we were iterating through 558 rows in the where condition.
# Not only that, we also saw in the execution plan that we were doing a full table scan that was quite inefficient and time consuming.
# To fix that we created the following index on status:
alter table sessions add index(status);
# With this index we stopped having a full table scan, and the cost info shown on the Execution Plan was much lower.

#2. 
# Selecting the three tutors with the best ratings (based on the average)
# explain
select t.tutor_name, 
	round(avg(r.rating_value), 2) as avg_rating
from ratings r
join sessions s on s.session_id = r.session_id
join tutors t on t.tutor_id = s.tutor_id
group by t.tutor_name
order by avg_rating desc
limit 3;

# Here we were having a Full Table Scan once again, this time on Ratings.
# This means that we were having no filtering at all, which is very costly for large tables (not the case since we only have 50 rows).
# Still, we tried to optimize this query by creating an index on rating_value, which resulted in a Full Index Scan.
# We understood that no matter what all rows would have to be scanned, and therefore we removed this index and did nothing else.
# Besides that, the query has a good performance.


# Selecting the three students that scheduled the most sessions
# explain
select s.student_name, 
	count(se.student_id) as 'Number of Sessions Scheduled'
from students s
join sessions se on se.student_id = s.student_id
where se.status = "done"
group by s.student_name
order by count(se.student_id) desc
limit 3;

alter table students add index(student_name);
# Adding an index on student_name stopped us from having a Full Table Scan.
# In this query, we are once again filtering by status which is optimized by the fact that we have an index on this variable.

# Selecting the three tutoring centres that have the most sessions scheduled
# explain
select tc.tutoring_centre_id, 
	tc.address, count(t.tutor_id) as 'Number of Sessions Held',
    m.municipality_name,
    d.district_name
from tutoring_centres tc
join municipalities m on m.municipality_id = tc.municipality_id
join districts d on d.district_id = m.district_id
join tutors t on t.tutoring_centre_id = tc.tutoring_centre_id
join sessions s on s.tutor_id = t.tutor_id
where s.status = "done"
group by tutoring_centre_id
order by count(t.tutor_id) desc
limit 3;

# The Execution Plan showed that we are doing a Full Index Scan on the tutoring centres table, but since this
# table only has 5 records this is not something to be concerned about (the cost info is still very small). 
# In this query, we are once again filtering by status which is optimized by the fact that we have an index on this variable.

#3.
# Getting the total and average amount of sales (by year and month) for a specific period of time (2019-11-03 to 2022-04-20).
# explain
select count(session_id) as 'Number of Sessions', 
	CONCAT(CAST(MIN(start_time) AS DATE),' - ',CAST(MAX(end_time) AS DATE)) as PeriodOfSales,
    ROUND(SUM(s.session_price),1) as TotalSales,
    ROUND(SUM(s.session_price)/TIMESTAMPDIFF(YEAR, MIN(start_time), MAX(end_time)),1) as YearlyAverage,
    ROUND(SUM(s.session_price)/TIMESTAMPDIFF(MONTH, MIN(start_time), MAX(end_time)),1) as MonthlyAverage
from sessions s
where s.status = "done";

# This simple query, where we access only one table, is going over 532 rows of the table session in a non-unique lookup on status (because of the previously created index).
# We have a Filtered value (ratio of rows produced per rows examined) of 100%, 
# which is good because it means that all examined rows are being returned.

#4.
# Getting the total sales by geographical location (district).
# explain
select d.district_name, 
	sum(s.session_price) as TotalSales
from tutors_courses tc
join sessions s on s.tutor_id = tc.tutor_id and s.SCHOOL_YEAR_ID = tc.SCHOOL_YEAR_ID and s.COURSE_ID = tc.COURSE_ID
join tutors t on tc.tutor_id = t.tutor_id
join tutoring_centres ttc on ttc.tutoring_centre_id = t.tutoring_centre_id
join municipalities m on m.municipality_id = ttc.municipality_id
join districts d on d.district_id = m.district_id
where s.status = 'done'
group by d.district_name;

# We are having a full index scan (5 rows) on the table tutoring_centres, but this cannot be fixed with the creation of an index 
# since the variable is municipality_id which is already a foreign key.
# There is also a non-unique key lookup (4 rows) on tutors with the foreign key tutoring_centre_id.
# Analysing the query stats, the timing measures at the client and server sides are very low.

#5.
# Selecting the districts where sessions were rated, and the amount of ratings made.
# explain
select d.district_name, 
	count(r.rating_id) as number_of_ratings
from districts d
join municipalities m on m.district_id = d.district_id
join tutoring_centres ttc on ttc.municipality_id = m.municipality_id
join tutors t on t.tutoring_centre_id = ttc.tutoring_centre_id
join sessions s on s.tutor_id = t.tutor_id 
join ratings r on s.session_id = r.session_id
group by d.district_name;

# We are having a full index scan (5 rows) on the table tutoring_centres, but this cannot be fixed with the creation of an index 
# since the variable is municipality_id which is already a foreign key.
# Analysing the query stats, the timing measures at the client and server sides are very low.

# --------------------------------------------------- Triggers --------------------------------------------------- 

# ------ Trigger 1 ------
# Before a new session is scheduled, we need to make sure that it complies with the following rules:
#		1. The ending time isn't smaller or equal to the starting time of the session
#		2. A session that is scheduled in the future cannot be inserted with the status 'done'
#		3. A session cannot be scheduled in the past
#		4. Only one session can be scheduled per tutor in a certain time slot. If a session has already been
#		   scheduled with that tutor in that period of time, and it hasn't been canceled, an error will be raised.
# We can insert sessions that have happened in the past with the status 'done', for invoice purposes.
# When a session is scheduled, the final price is automatically calculated based on the tutor's pay rate, specified
# in the tutors_courses table
drop trigger if exists session_integrity;
delimiter $$
create trigger session_integrity before insert
on sessions
for each row
begin
	if new.end_time <= new.start_time then
		signal sqlstate '45000' SET MESSAGE_TEXT = 'The ending time of the session cannot be before the starting time.';
	elseif new.status = 'done' 
		and new.start_time > NOW() then
		signal sqlstate '45000' SET MESSAGE_TEXT = 'You cannot schedule a session with a status equal to "done".';
    elseif new.status = 'scheduled'
		and new.start_time < NOW() then
		signal sqlstate '45000' SET MESSAGE_TEXT = 'You cannot schedule a session in the past.';
    elseif exists (select start_time, end_time from sessions
		where start_time <= new.end_time
		and end_time >= new.start_time
        and new.tutor_id = tutor_id
        and status != 'canceled') then
		signal sqlstate '45000' SET MESSAGE_TEXT = 'There is already a session with this tutor in this time slot.';
	else
		set new.session_price = (select tc.pay_per_hour * hour(new.end_time - new.start_time)
								from tutors_courses as tc 
								where tc.tutor_id = new.tutor_id 
								and tc.course_id = new.course_id 
								and tc.school_year_id = new.school_year_id
                                limit 1);
    end if;
end $$
delimiter ;

# Testing Trigger 1

# Raises 1st error 
insert into sessions (start_time, end_time, status, tutor_id, course_id, school_year_id, student_id) values ("2021-07-11 18:00:00", "2021-07-11 17:00:00", "done", 13, 21, 7, 19);

# Raises 2nd error
insert into sessions (start_time, end_time, status, tutor_id, course_id, school_year_id, student_id) values ("2023-07-11 17:00:00", "2023-07-11 18:00:00", "done", 13, 21, 7, 19);

# Raises 3rd error
insert into sessions (start_time, end_time, status, tutor_id, course_id, school_year_id, student_id) values ("2021-07-11 12:00:00", "2021-07-11 13:00:00", "scheduled", 13, 21, 7, 19);

# Raises 4th error
insert into sessions (start_time, end_time, status, tutor_id, course_id, school_year_id, student_id) values ("2023-01-11 17:00:00", "2023-01-11 18:00:00", "scheduled", 13, 21, 7, 2);

# Inserts correctly
insert into sessions (start_time, end_time, status, tutor_id, course_id, school_year_id, student_id) values ("2023-01-15 17:00:00", "2023-01-15 19:00:00", "scheduled", 13, 21, 7, 2);

select * from sessions where end_time = "2023-01-15 19:00:00";

# ------ Trigger 2 ------
# This trigger is meant to assure that users (students) cannot cancel a session that has already occured, that is,
# a session where the status is equal to 'done'
drop trigger if exists prohibit_cancel;
delimiter $$
create trigger prohibit_cancel before update
on sessions
for each row
begin
	if old.status = 'done' 
		and new.status = 'canceled' then
		signal sqlstate '45000' SET MESSAGE_TEXT = 'You cannnot cancel a session that has already happened';
    end if;
end $$
delimiter ;

# Testing Trigger 2
update sessions set status='canceled' where session_id=1; #this should not work

update sessions set status ='canceled' where session_id=581; #this should update the status of the session to 'canceled'

select session_id, status from sessions where session_id = 1 or session_id=581;

# ------ Trigger 3 ------
# When a tutor's pay rate is updated, the price of every session that they have scheduled in the future will be
# updated according to the new price per hour
drop trigger if exists update_session_price;
delimiter $$
create trigger update_session_price after update
on tutors_courses
for each row
begin
	if old.pay_per_hour != new.pay_per_hour then
		update sessions 
        set session_price = new.pay_per_hour * hour(end_time - start_time)
        where sessions.tutor_id = new.tutor_id 
        and sessions.course_id = new.course_id 
        and sessions.school_year_id = new.school_year_id
        and sessions.status = 'scheduled';
    end if;
end $$
delimiter ;

# Testing Trigger 3

# Scheduling a two-hour session in January of 2023 with tutor 1 of course 1 of 10th grade 
insert into sessions (start_time, end_time, status, tutor_id, course_id, school_year_id, student_id) values ("2023-01-20 17:00:00", "2023-01-20 19:00:00", "scheduled", 1, 1, 10, 2);

#Check price
select * from sessions where tutor_id = 1 and end_time = "2023-01-20 19:00:00";

# Updating tutor 1's pay rate in course 1 of 10th grade from 22€ to 23€
update tutors_courses set pay_per_hour = 23.00 where tutor_id = 1 and course_id=1 and school_year_id = 10;

#Check if the price has changed
select * from sessions where tutor_id = 1 and end_time = "2023-01-20 19:00:00";


# ----------------------------------------------- LOG Triggers ----------------------------------------------- 

# ------ LOG Trigger 1 ------
# Every time a new user is created on our platform, this action will be recorded on the LOGS table
drop trigger if exists after_student_insert;
delimiter $$
create trigger after_student_insert
after insert
on students
for each row
begin
	insert into logs (CREATED_AT, STUDENT_ID, STUDENT_NAME, EVENT_TYPE, NEW_RECORD) values 
    (NOW(), new.student_id, new.student_name , "Insert",concat(new.student_name, '; ', new.student_birthday, '; ', new.student_contact, '; ', new.student_gender, '; ', new.current_school_year));
end$$
delimiter ;

#Testing LOG Trigger 1
insert into 
students (student_name, student_birthday, student_contact, student_gender, current_school_year) 
values ("Inês Santos", "2001-11-26", "ines@gmail.com", "f", 12);

select * from logs;

# ------ LOG Trigger 2 ------
# Every time a user deletes their account, this action will be recorded on the LOGS table
drop trigger if exists after_student_delete;
delimiter $$
create trigger after_student_delete
after delete
on students
for each row
begin
	insert into logs (CREATED_AT, STUDENT_ID, STUDENT_NAME, EVENT_TYPE, OLD_RECORD) values 
    (NOW(), old.student_id, old.student_name , "Delete", concat(old.student_name, '; ', old.student_birthday, '; ', old.student_contact, '; ', old.student_gender, '; ', old.current_school_year));
end$$
delimiter ;

#Testing LOG Trigger 2
delete from students where student_id = 53;

select * from logs;

# ------ LOG Trigger 3 ------
# Every time a user updates their account, this action will be recorded on the LOGS table, along with the information
# that has been altered
drop trigger if exists after_student_update;
delimiter $$
create trigger after_student_update
after update
on students
for each row
begin
	insert into logs (CREATED_AT, STUDENT_ID, STUDENT_NAME, EVENT_TYPE, OLD_RECORD, NEW_RECORD) values 
    (NOW(), old.student_id, old.student_name , "Update", concat(old.student_name, '; ', old.student_birthday, '; ', old.student_contact, '; ', old.student_gender, '; ', old.current_school_year), concat(new.student_name, '; ', new.student_birthday, '; ', new.student_contact, '; ', new.student_gender, '; ', new.current_school_year));
end$$
delimiter ;

# Testing LOG Trigger 3
update students set student_name = "Avó Cantigas" where student_id = 1;

select * from logs;

# INVOICE
# For each individual session an invoice is printed.

drop view if exists invoice_head; 
create view invoice_head as
	select session_id as 'Invoice Number',
		student_name,
        student_contact,
        tutor_name,
        time(end_time - start_time) as 'Session Duration',
		date(start_time) as 'Date of Issue',
        date(date_add(start_time, INTERVAL 7 DAY)) as 'Due Date',
        round(session_price * 0.94, 2) as SubTotal,
        round(session_price * 0.06, 2) as 'IVA (6%)',
        round(session_price,2) as Amount,
        address,
        tutoring_centre_contact
	from students st
	join sessions se on se.student_id = st.student_id
	join tutors_courses tc on tc.tutor_id = se.tutor_id
    join tutors t on t.tutor_id = tc.tutor_id
    join tutoring_centres tuc on tuc.tutoring_centre_id = t.tutoring_centre_id
	where se.course_id = tc.course_id
	and se.school_year_id = tc.school_year_id
;

select * from invoice_head
where `Invoice Number` = 100;

drop view if exists invoice_details;
create view invoice_details as
	select session_id,
		tutor_name,
        course_name,
        s.school_year_id as 'School Year',
        pay_per_hour as 'Unit Cost',
        time(end_time - start_time) as 'Session Duration',
        session_price as 'Amount'
from sessions s
join tutors_courses tc on tc.tutor_id = s.tutor_id
join courses c on c.course_id = tc.course_id
join tutors t on t.tutor_id = tc.tutor_id
where s.course_id = tc.course_id
and s.school_year_id = tc.school_year_id
;

select * from invoice_details
where `Invoice Number` = 100;