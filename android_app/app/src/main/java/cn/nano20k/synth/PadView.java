package cn.nano20k.synth;

import android.content.Context;
import android.graphics.*;
import android.os.*;
import android.view.*;
import android.view.accessibility.*;
import cn.nano20k.synth.core.Notes;
import cn.nano20k.synth.core.Practice;
import java.util.*;

public final class PadView extends View {
    private final Session session;private final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);private final Map<Integer,Integer> fingers=new HashMap<>();
    private final RectF[] pads=new RectF[8];private boolean gesture;
    private final boolean practiceMode;
    private final Runnable update;
    public PadView(Context c,Session s){this(c,s,false,()->{});}
    public PadView(Context c,Session s,boolean practiceMode,Runnable update){super(c);session=s;this.practiceMode=practiceMode;this.update=update;for(int i=0;i<8;i++)pads[i]=new RectF();setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_YES);setContentDescription(practiceMode?"八键练习提示区":"八键演奏区，支持多指和弦；点击一个琴键发音");setFocusable(true);}
    private boolean touchEnabled(){return practiceMode?session.practice!=null&&!session.physicalPractice&&!session.practice.done():session.usable();}
    private float d(float x){return x*getResources().getDisplayMetrics().density;}
    @Override protected void onSizeChanged(int w,int h,int oldW,int oldH){float gap=d(10),pw=(w-gap*3)/4,ph=(h-gap)/2;for(int i=0;i<8;i++)pads[i].set((i%4)*(pw+gap),(i/4)*(ph+gap),(i%4)*(pw+gap)+pw,(i/4)*(ph+gap)+ph);}
    @Override protected void onDraw(Canvas c){super.onDraw(c);Practice practice=session.practice;
        int[] pitches=practiceMode&&practice!=null&&session.practiceMapped()?practice.keys():null;
        int targets=pitches==null?0:practice.target();
        for(int i=0;i<8;i++){RectF r=pads[i];boolean held=practiceMode?practice!=null&&(practice.held()&(1<<i))!=0:(session.mask()&(1L<<session.mapping[i]))!=0;
        boolean target=(targets&(1<<i))!=0;
        paint.setColor(held?0xff65e1c2:target?0xff2f5550:0xff202d36);c.drawRoundRect(r,d(16),d(16),paint);
        paint.setStyle(Paint.Style.STROKE);paint.setStrokeWidth(d(target?2:1));paint.setColor(held||target?0xffa3ffe8:0xff344650);c.drawRoundRect(r,d(16),d(16),paint);paint.setStyle(Paint.Style.FILL);
        String label=practiceMode?pitches!=null&&pitches[i]>=0?Notes.midiLabel(pitches[i]):"·":Notes.label(session.mapping[i]);
        paint.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));paint.setTextSize(d(25));paint.setColor(held?0xff10221e:0xfff0f5f5);paint.setTextAlign(Paint.Align.CENTER);c.drawText(label,r.centerX(),r.centerY()+d(3),paint);
        paint.setTextSize(d(10));paint.setColor(held?0xff194338:0xff92a6b1);c.drawText("0"+(i+1),r.centerX(),r.bottom-d(15),paint);
        paint.setColor(held?0xff153e31:0xff4a606d);c.drawCircle(r.centerX(),r.top+d(17),d(2.5f),paint);
    }}
    private int padAt(float x,float y){for(int i=0;i<8;i++)if(pads[i].contains(x,y))return i;return -1;}
    private void lift(int pointer){
        Integer key=fingers.remove(pointer);
        if(!practiceMode)session.release("finger"+pointer);
        else if(key!=null&&!fingers.containsValue(key)&&touchEnabled()){session.practice.input(key,false);update.run();}
    }
    private void move(int pointer,float x,float y){
        int key=padAt(x,y);Integer prior=fingers.get(pointer);
        if(prior!=null&&prior==key)return;
        if(prior!=null)lift(pointer);
        if(key<0||!touchEnabled())return;
        boolean held=fingers.containsValue(key);fingers.put(pointer,key);
        if(!practiceMode)session.press("finger"+pointer,session.mapping[key]);
        else if(!held){session.practice.input(key,true);update.run();}
    }
    @Override public boolean onTouchEvent(MotionEvent event){int action=event.getActionMasked(),i=event.getActionIndex();
        if(action==MotionEvent.ACTION_DOWN)gesture=touchEnabled();
        if(!gesture)return true;
        if(action==MotionEvent.ACTION_DOWN||action==MotionEvent.ACTION_POINTER_DOWN){if(!touchEnabled())return true;getParent().requestDisallowInterceptTouchEvent(true);move(event.getPointerId(i),event.getX(i),event.getY(i));}
        else if(action==MotionEvent.ACTION_MOVE){for(int n=0;n<event.getPointerCount();n++)move(event.getPointerId(n),event.getX(n),event.getY(n));}
        else if(action==MotionEvent.ACTION_UP||action==MotionEvent.ACTION_POINTER_UP){lift(event.getPointerId(i));if(action==MotionEvent.ACTION_UP){gesture=false;getParent().requestDisallowInterceptTouchEvent(false);performClick();}}
        else if(action==MotionEvent.ACTION_CANCEL)releaseFingers();invalidate();return true;
    }
    public void releaseFingers(){gesture=false;if(practiceMode){if(touchEnabled())session.practice.cancelTouches();}else for(int pointer:new ArrayList<>(fingers.keySet()))session.release("finger"+pointer);fingers.clear();invalidate();}
    @Override public boolean performClick(){super.performClick();return true;}
    @Override public AccessibilityNodeProvider getAccessibilityNodeProvider(){return provider;}
    private final AccessibilityNodeProvider provider=new AccessibilityNodeProvider(){
        @Override public AccessibilityNodeInfo createAccessibilityNodeInfo(int id){
            AccessibilityNodeInfo n=AccessibilityNodeInfo.obtain();if(id==View.NO_ID){onInitializeAccessibilityNodeInfo(n);for(int i=0;i<8;i++)n.addChild(PadView.this,i);return n;}
            if(id<0||id>=8)return null;n.setSource(PadView.this,id);n.setParent(PadView.this);n.setPackageName(getContext().getPackageName());n.setClassName("android.widget.Button");
            Practice p=session.practice;int midi=practiceMode&&p!=null&&session.practiceMapped()?p.keys()[id]:-1;
            String label=practiceMode?midi<0?"空键":Notes.midiLabel(midi)+((p.target()&(1<<id))!=0?"，目标":""):Notes.label(session.mapping[id]);
            n.setContentDescription("琴键 "+(id+1)+"，"+label);n.setClickable(touchEnabled());n.setEnabled(touchEnabled());n.setVisibleToUser(isShown());if(touchEnabled())n.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_CLICK);n.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_ACCESSIBILITY_FOCUS);
            Rect bounds=new Rect();pads[id].round(bounds);n.setBoundsInParent(bounds);int[] pos=new int[2];getLocationOnScreen(pos);bounds.offset(pos[0],pos[1]);n.setBoundsInScreen(bounds);return n;
        }
        @Override public boolean performAction(int id,int action,Bundle args){if(id<0||id>=8)return false;if(action==AccessibilityNodeInfo.ACTION_CLICK&&touchEnabled()){
            if(practiceMode){Practice p=session.practice;boolean down=(p.held()&(1<<id))==0;p.input(id,down);if(down&&p.waitingForRelease())for(int key=0;key<8;key++)p.input(key,false);update.run();}
            else{session.press("access"+id,session.mapping[id]);new Handler(Looper.getMainLooper()).postDelayed(()->session.release("access"+id),250);}return true;}if(action==AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS){AccessibilityEvent event=AccessibilityEvent.obtain(AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUSED);event.setSource(PadView.this,id);sendAccessibilityEventUnchecked(event);return true;}return false;}
    };
}
