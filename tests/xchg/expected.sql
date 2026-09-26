-- the data of FAND task xchg
/*!40101 SET NAMES utf8mb4 */;
SET FOREIGN_KEY_CHECKS=0;

DROP TABLE IF EXISTS `ITEMS`;
CREATE TABLE `ITEMS` (
  `fand_row` int(10) unsigned NOT NULL COMMENT 'the record''s place in the FAND file',
  `Code` varchar(6) DEFAULT NULL COMMENT 'FAND A,6',
  `Name` varchar(30) DEFAULT NULL COMMENT 'FAND A,30',
  `Cust` varchar(10) DEFAULT NULL COMMENT 'FAND A,10R',
  `Qty` varchar(5) DEFAULT NULL COMMENT 'FAND N,5',
  `Serial` varchar(6) DEFAULT NULL COMMENT 'FAND N,6L',
  `Price` decimal(12,2) DEFAULT NULL COMMENT 'FAND F,9.2',
  `Units` decimal(7,0) DEFAULT NULL COMMENT 'FAND F,6',
  `Cents` decimal(10,2) DEFAULT NULL COMMENT 'FAND F,7,2',
  `Rate` double DEFAULT NULL COMMENT 'FAND R',
  `Due` date DEFAULT NULL COMMENT 'FAND D,\'DD.MM.YYYY\'',
  `Stamp` datetime DEFAULT NULL COMMENT 'FAND D,\'DD.MM.YYYY hh:mm:ss\'',
  `Clock` time(2) DEFAULT NULL COMMENT 'FAND D,\'hh:mm:ss.tt\'',
  `Paid` tinyint(1) DEFAULT NULL COMMENT 'FAND B',
  `Note` mediumtext DEFAULT NULL COMMENT 'FAND T',
  KEY `key1` (`Code`),
  PRIMARY KEY (`fand_row`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='FAND file type X';
INSERT INTO `ITEMS` VALUES
(1,'C3','Ďábelské ódy - "uvozovky"','X','99999','999999',999999999.99,-999999,-99999.99,1.5E20,'1999-12-31','2000-02-29 23:59:59','23:59:59.99',1,'ASCII only'),
(2,'A1','Žluťoučký kůň úpěl','ACME','00042','120000',1234.50,7,12.34,3.14159265359,'2026-09-24','2026-09-24 13:45:07','08:30:15.25',1,'Line one\r\nLine two bold & <tag> "quoted"\r\n	tab'),
(3,'B2','','',NULL,'700000',NULL,NULL,-0.05,NULL,NULL,NULL,'00:00:00.00',0,'');

DROP TABLE IF EXISTS `NOTES`;
CREATE TABLE `NOTES` (
  `fand_row` int(10) unsigned NOT NULL COMMENT 'the record''s place in the FAND file',
  `Title` varchar(40) DEFAULT NULL COMMENT 'FAND A,40',
  `Body` mediumtext DEFAULT NULL COMMENT 'FAND T',
  PRIMARY KEY (`fand_row`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='FAND file type 6';
INSERT INTO `NOTES` VALUES
(1,'Hello','first line\r\nsecond line'),
(2,'it\'s','');

SET FOREIGN_KEY_CHECKS=1;
