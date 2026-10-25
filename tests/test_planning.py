"""Collection plans must count reproductive stock and never mutate components."""
import unittest
import test_runtime as runtime

SETUP = r'''
stateFiles['/home/.openbeekeeper-data/roles']='OpenBeekeeper-roles-2\nnetwork me\n'
function stack(uid,name,kind,count)
 return {name='forestry:bee_'..kind..'_ge',label=name..' '..kind,size=count,
   individual={ident=uid,displayName=name}}
end
function catalogue(address)
 devices[address]={kind='bee_housing',
   listAllSpecies=function() catalogueReads=catalogueReads+1
     return {{uid='a',name='A'},{uid='b',name='B'},{uid='c',name='C'}} end,
   getBeeBreedingData=function() return {
     {allele1='A',allele2='B',result='C',chance=12,specialConditions={'During the night.'}}} end}
end
catalogueReads=0
'''


class PlanningTests(unittest.TestCase):
    def plan(self, code=''):
        return runtime.RuntimeTests().run_script(SETUP+code, 'plan')

    def test_surplus_drones_leave_one_reserved(self):
        text, _, lua=self.plan("network('me',{stack('a','A','drone',64)})")
        self.assertIn('A P=0 D=64 Q=0 | SAMPLE CANDIDATE: 63 surplus', text)
        self.assertEqual(len(list(lua.globals().networkCalls.values())), 1)
        self.assertIn('No items moved', text)

    def test_princess_is_not_a_sampler_donor(self):
        text, _, _=self.plan("network('me',{stack('a','A','princess',8)})")
        self.assertIn('P=8 D=0 Q=0 | MISSING PARENT', text)
        self.assertIn('sample candidates: 0', text)

    def test_pair_and_queen_are_separate_reproduction_actions(self):
        text, _, _=self.plan("network('me',{stack('a','A','princess',1),stack('a','A','drone',1),stack('b','B','queen',1)})")
        self.assertIn('P=1 D=1 Q=0 | REPRODUCE', text)
        self.assertIn('P=0 D=0 Q=1 | APIARY', text)

    def test_labels_remain_review_only(self):
        text, _, _=self.plan("network('me',{{name='gendustry:gene_sample',label='Bee Sample - Species: A',size=1},stack('a','A','drone',8)})")
        self.assertIn('REVIEW: sample label present', text)
        self.assertIn('sample candidates: 0', text)

    def test_nbt_species_sample_kept_but_speed_does_not_count(self):
        text, _, _=self.plan("network('me',{sample('a',0),sample('b',1),stack('a','A','drone',8),stack('b','B','drone',8)})")
        self.assertIn('A P=0 D=8 Q=0 | KEEP', text)
        self.assertIn('B P=0 D=8 Q=0 | SAMPLE CANDIDATE', text)

    def test_mutation_direction_conditions_and_last_parent_review(self):
        text, _, lua=self.plan("catalogue('h1'); catalogue('h2'); network('me',{stack('b','B','princess',1),stack('a','A','drone',1)})")
        self.assertIn('B (P) + A (D) -> C | 12%', text)
        self.assertIn('REVIEW: last parent', text)
        self.assertIn('CONDITIONS: During the night.', text)
        self.assertEqual(lua.globals().catalogueReads, 1)

    def test_observed_result_not_presented_as_new_species(self):
        text, _, _=self.plan("catalogue('h'); network('me',{stack('a','A','princess',2),stack('b','B','drone',2),stack('c','C','drone',1)})")
        self.assertNotIn('-> C', text)

    def test_ambiguous_names_never_choose_a_mutation_uid(self):
        text, _, _=self.plan("catalogue('h'); network('me',{stack('x','A','princess',2),stack('y','A','princess',2),stack('b','B','drone',2)})")
        self.assertNotIn('-> C', text)

    def test_second_invocation_reuses_shared_snapshot(self):
        _, _, lua=self.plan("network('me',{stack('a','A','drone',2)})")
        lua.execute('clock=10')
        lua.eval('function(src) return assert(load(src))("plan") end')(runtime.SOURCE)
        self.assertEqual(list(lua.globals().networkCalls.values()), [0])


if __name__ == '__main__':
    unittest.main()
