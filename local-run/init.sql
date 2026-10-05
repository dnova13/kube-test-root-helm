-- 로컬 실행용 스키마. part3-infra/README.md의 DDL(social_feed)과 part3-infra/ddl.sql의 mail_sent_datetime을 합친 것
create database if not exists sns;
use sns;

create user if not exists 'sns-server'@'%' identified by 'password!';
grant all privileges on sns.* to 'sns-server'@'%';

create table social_feed
(
    feed_id         int auto_increment primary key,
    image_id        varchar(255)                       not null,
    uploader_id     int                                not null,
    upload_datetime datetime default CURRENT_TIMESTAMP null,
    contents        text                               null
);

create table user
(
    user_id  int auto_increment primary key,
    username varchar(255) not null,
    email    varchar(255) not null,
    password varchar(255) not null
);

create table follow
(
    follow_id          int auto_increment primary key,
    user_id            int                                not null,
    follower_id        int                                not null,
    follow_datetime    datetime default CURRENT_TIMESTAMP null,
    mail_sent_datetime datetime default null
);
