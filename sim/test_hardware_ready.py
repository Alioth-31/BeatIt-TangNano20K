"""First-connection checks reuse the existing protocol and calibration contract."""
import sys
import unittest
import io
import json
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
import hardware_ready as h


class PeripheralLink:
    def __init__(self,present=True):
        self.present=present;self.writes=[];self.fail_once=None
        self.decoder=type('Decoder',(),{'errors':0})();self.gaps=0
        self.states=[dict(channel=i,adc_available=present,sample_valid=present,
                         led_available=present,arithmetic_fault=False,raw=800,
                         low=0,centre=0,high=0,calibrated=False,enabled=False,
                         invert_x=False,active=False) for i in range(3)]
    def request(self,*args,**kwargs):return bytes.fromhex('01 20 ff 80 bb 00 00 ff ff ff ff 01 01')
    def status(self):return dict(active=0,faults=0,volume=6554)
    def performance(self):return dict(timbre=0)
    def guide(self):return dict(led_available=int(self.present),blocked_reason=0 if self.present else 4)
    def expression(self,channel):return dict(self.states[channel])
    def set_expression(self,channel,low,centre,high,enable=False,invert_x=False):
        self.writes.append((channel,enable))
        if channel==self.fail_once:self.fail_once=None;raise TimeoutError('injected timeout')
        self.states[channel].update(low=low,centre=centre,high=high,calibrated=True,
                                    enabled=enable,invert_x=invert_x,active=enable)


def profile():
    return {'schema':2,'channels':[
        dict(channel=1,low=100,centre=800,high=1500,invert_x=True),
        dict(channel=2,low=160,centre=810,high=1470,invert_x=False)]}


class HardwareReadyTests(unittest.TestCase):
    def test_missing_peripherals_are_pending_and_inspection_never_writes(self):
        link=PeripheralLink(False);state=h.inspect(link)
        self.assertTrue(state['digital_link_ok']);self.assertFalse(state['peripherals_present'])
        self.assertFalse(state['expression_ready']);self.assertTrue(state['pending']);self.assertEqual(link.writes,[])

    def test_held_physical_input_is_not_reported_as_idle(self):
        link=PeripheralLink()
        link.status=lambda:dict(active=1,faults=0,volume=6554,remote_mask=0)
        link.performance=lambda:dict(timbre=0,physical_debounced=2,play_keys=2)
        state=h.inspect(link)
        self.assertTrue(state['digital_link_ok']);self.assertFalse(state['inputs_idle'])
        self.assertTrue(any('未释放' in s for s in state['pending']));self.assertEqual(link.writes,[])

    def test_strict_startup_rejects_held_inputs_before_applying_calibration(self):
        link=PeripheralLink();link.status=lambda:dict(active=1,faults=0,volume=6554,remote_mask=0)
        link.performance=lambda:dict(timbre=0,physical_debounced=2,play_keys=2)
        folder=Path(__file__).resolve().parents[1]/'build/hardware-ready-tests';folder.mkdir(parents=True,exist_ok=True)
        settings=folder/'profile.json';settings.write_text(json.dumps(profile()),encoding='utf-8')
        argv=['hardware_ready.py','--port','memory','--direct','--require-idle','--profile',str(settings),
              '--output',str(folder/'held-input.json'),'apply']
        with patch.object(sys,'argv',argv),patch('serial.Serial'),patch.object(h.protocol,'DeviceLink',return_value=link),\
             patch.object(h.time,'sleep'),redirect_stdout(io.StringIO()),self.assertRaises(SystemExit) as exited:
            h.main()
        self.assertNotEqual(exited.exception.code,0);self.assertEqual(link.writes,[])

    def test_profile_is_fully_validated_before_any_mutation(self):
        for bad in ('span','duplicate','missing','bool'):
            link=PeripheralLink();data=profile()
            if bad=='span':data['channels'][1]['high']=data['channels'][1]['centre']+1
            if bad=='duplicate':data['channels'][1]['channel']=1
            if bad=='missing':data['channels'].pop()
            if bad=='bool':data['channels'][1]['low']=True
            with self.subTest(bad=bad),self.assertRaises(ValueError):h.apply_profile(link,data)
            self.assertEqual(link.writes,[])

    def test_apply_requires_live_adc_and_verifies_all_channels(self):
        link=PeripheralLink(False)
        with self.assertRaises(RuntimeError):h.apply_profile(link,profile())
        self.assertEqual(link.writes,[])
        link=PeripheralLink()
        with patch.object(h.time,'sleep'):result=h.apply_profile(link,profile())
        self.assertTrue(result['expression_ready'])
        self.assertEqual(link.writes,[(1,False),(2,False),(1,True),(2,True)])
        self.assertTrue(link.expression(1)['invert_x'])

    def test_failed_apply_disables_every_channel_and_reports_failure(self):
        link=PeripheralLink();link.fail_once=1
        with patch.object(h.time,'sleep'),self.assertRaises(TimeoutError):h.apply_profile(link,profile())
        self.assertFalse(any(s['enabled'] for s in link.states))
        self.assertTrue(all((i,False) in link.writes for i in (1,2)))

    def test_adc_loss_during_staging_never_enables_any_channel(self):
        class LostADC(PeripheralLink):
            def set_expression(self,*args,**kwargs):
                super().set_expression(*args,**kwargs)
                for state in self.states:state['adc_available']=False
        link=LostADC()
        with patch.object(h.time,'sleep'),self.assertRaises(RuntimeError):h.apply_profile(link,profile())
        self.assertFalse(any(enabled for _,enabled in link.writes))

    def test_keyboard_interrupt_during_apply_also_disables_every_channel(self):
        class Interrupted(PeripheralLink):
            def set_expression(self,*args,**kwargs):
                super().set_expression(*args,**kwargs)
                if args[0]==1 and kwargs.get('enable'):raise KeyboardInterrupt()
        link=Interrupted()
        with patch.object(h.time,'sleep'),self.assertRaises(KeyboardInterrupt):h.apply_profile(link,profile())
        self.assertFalse(any(state['enabled'] for state in link.states))

    def test_wizard_measures_actual_positions_and_infers_x_direction(self):
        link=PeripheralLink();positions=iter(((1,1500),(1,800),(1,100),(2,160),(2,810),(2,1470)))
        def prompt(message):
            channel,value=next(positions);link.states[channel]['raw']=value
        with patch.object(h.time,'sleep'):data=h.capture_profile(link,prompt=prompt,samples=5)
        self.assertEqual(data['channels'],profile()['channels']);self.assertEqual(link.writes,[])

    def test_pressure_channel_is_not_needed_or_written(self):
        link=PeripheralLink();link.states[0].update(adc_available=False,sample_valid=False)
        with patch.object(h.time,'sleep'):state=h.apply_profile(link,profile())
        self.assertTrue(state['expression_ready']);self.assertFalse(any(i==0 for i,_ in link.writes))
        legacy={'schema':1,'channels':[dict(channel=0,low=0,centre=0,high=1600,invert_x=False),*profile()['channels']]}
        self.assertEqual(h.validate_profile(legacy),profile()['channels'])

    def test_capture_does_not_turn_disconnected_or_flat_sensor_into_calibration(self):
        link=PeripheralLink(False)
        with patch.object(h.time,'sleep'),self.assertRaises(RuntimeError):
            h.capture_profile(link,prompt=lambda _:None,samples=3)
        link=PeripheralLink()
        with patch.object(h.time,'sleep'),self.assertRaises(ValueError) as rejected:
            h.capture_profile(link,prompt=lambda _:None,samples=3)
        self.assertTrue(hasattr(rejected.exception,'rejected_profile'))
        self.assertEqual(len(rejected.exception.rejected_profile['measurements']),6)
        self.assertEqual(link.writes,[])


if __name__=='__main__':unittest.main()
