<?xml version="1.0" encoding="UTF-8"?>
<map version="1.0.1">
  <node ID="ID_ROOT" TEXT="产品 Vision 🚀" FOLDED="false">
    <richcontent TYPE="NOTE">
      <html>
        <head/>
        <body>
          <p>First note line</p>
          <p>Second &amp; line</p>
        </body>
      </html>
    </richcontent>
    <node ID="ID_R" TEXT="Research 论文" POSITION="right">
      <attribute NAME="arbor-tags" VALUE="alpha,高优先"/>
      <attribute NAME="arbor-task-due" VALUE="2026-12-01"/>
      <node ID="ID_R1" TEXT="Paper draft" LINK="https://example.com/paper">
        <arrowlink DEST="ID_S"/>
      </node>
    </node>
    <node ID="ID_S" TEXT="Ship it" POSITION="left" FOLDED="true">
      <icon BUILTIN="button_ok"/>
    </node>
  </node>
</map>
