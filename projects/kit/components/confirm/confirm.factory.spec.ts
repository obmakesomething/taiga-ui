/* eslint-disable rxjs/no-ignored-observable */
import {type tuiDialog} from '@taiga-ui/core';
import {TuiConfirm, type TuiConfirmData} from '@taiga-ui/kit';
import {EMPTY} from 'rxjs';

const tuiDialogMock: typeof tuiDialog = jest.fn(() => jest.fn(() => EMPTY));

const dialog = tuiDialogMock(TuiConfirm);
const data: TuiConfirmData = {content: 'Confirm?'};

dialog(data).subscribe((_value: boolean) => {});
dialog(undefined).subscribe((_value: boolean) => {});
// @ts-expect-error TS2554: Expected 1 arguments, but got 0
dialog();
// @ts-expect-error TS2345: Argument of type `string` is not assignable to parameter of type `TuiConfirmData`
dialog('invalid');

describe('TuiConfirm dialog factory inference', () => {
    it('stub', () => {
        expect(true).toBeTruthy();
    });
});
