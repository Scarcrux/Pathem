import tempfile,unittest
from pathlib import Path
from transient_inventory import validate_standard_menus

class StandardMenuControls(unittest.TestCase):
    def fixture(self,code='let item = NSMenuItem()\nlist.menu = provider.menu\n'):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup);root=Path(temp.name)
        file='Sources/Pathem/FileContextMenu.swift';path=root/file;path.parent.mkdir(parents=True);path.write_text(code)
        key='Sources/Pathem/KeyTableView.swift:80:17:popUpContextMenu'
        data={'sites':{key:{'class':'C','standard_menu_providers':[file],'attachment_locations':[{'file':file,'line':2,'expression':'list.menu = provider.menu'}]}}}
        return root,path,data,key
    def test_reviewed_standard_menu_passes(self):
        root,_,d,_=self.fixture();self.assertEqual(validate_standard_menus(root,d),[])
    def test_custom_item_view_requires_class_a_review(self):
        root,p,d,_=self.fixture();p.write_text(p.read_text()+'item.view = NSView()\n')
        self.assertTrue(any('effective class A' in x for x in validate_standard_menus(root,d)))
    def test_multiline_optional_assignment_cannot_escape(self):
        root,p,d,_=self.fixture();p.write_text(p.read_text()+'item? .\n view\n = NSView()\n')
        self.assertTrue(validate_standard_menus(root,d))
    def test_comment_or_string_assignment_does_not_change_class(self):
        root,p,d,_=self.fixture();p.write_text(p.read_text()+'// item.view = custom\nlet text = "item.view = custom"\n')
        self.assertEqual(validate_standard_menus(root,d),[])
    def test_missing_provider_is_not_safe_by_default(self):
        root,p,d,_=self.fixture();p.unlink();self.assertTrue(validate_standard_menus(root,d))
    def test_stale_attachment_is_rejected(self):
        root,_,d,k=self.fixture();d['sites'][k]['attachment_locations'][0]['line']=1
        self.assertTrue(validate_standard_menus(root,d))
    def test_unreviewed_class_c_downgrade_is_rejected(self):
        root,_,d,k=self.fixture();d['sites'][k].pop('standard_menu_providers')
        self.assertTrue(validate_standard_menus(root,d))
    def test_reviewed_class_a_is_never_auto_downgraded(self):
        root,p,d,k=self.fixture();d['sites'][k]['class']='A';p.write_text(p.read_text()+'item.view = NSView()\n')
        self.assertEqual(validate_standard_menus(root,d),[])
