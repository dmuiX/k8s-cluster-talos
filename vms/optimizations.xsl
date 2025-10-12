<?xml version="1.0" ?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output omit-xml-declaration="yes" indent="yes"/>
  
  <xsl:template match="node()|@*">
    <xsl:copy>
      <xsl:apply-templates select="node()|@*"/>
    </xsl:copy>
  </xsl:template>
  
  <!-- IOThreads -->
  <xsl:template match="/domain[not(iothreads)]">
    <xsl:copy>
      <xsl:apply-templates select="@*"/>
      <iothreads>2</iothreads>
      <xsl:apply-templates select="node()"/>
    </xsl:copy>
  </xsl:template>
  
  <xsl:template match="/domain/iothreads">
    <iothreads>2</iothreads>
  </xsl:template>
  
  <xsl:template match="/domain/devices/disk[@device='disk']/driver[not(@iothread)]">
    <xsl:copy>
      <xsl:apply-templates select="@*"/>
      <xsl:attribute name="iothread">1</xsl:attribute>
      <xsl:apply-templates select="node()"/>
    </xsl:copy>
  </xsl:template>
  
  <!-- Clock timers -->
  <xsl:template match="/domain/clock/timer[@name='hpet']"/>
  
  <xsl:template match="/domain/clock">
    <xsl:copy>
      <xsl:apply-templates select="@*|node()"/>
      <timer name="hpet" present="no"/>
    </xsl:copy>
  </xsl:template>
</xsl:stylesheet>
